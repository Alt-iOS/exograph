defmodule Exograph.Query do
  @moduledoc """
  Compiled query plan for candidate retrieval and exact verification.
  """

  alias Exograph.AST.Terms

  defstruct source: nil,
            required_terms: MapSet.new(),
            optional_terms: MapSet.new(),
            negative_terms: MapSet.new(),
            candidate_groups: [],
            verifier: nil

  @type verifier :: {:pattern, ExAST.Pattern.pattern()} | {:selector, ExAST.Selector.t()} | nil

  @type t :: %__MODULE__{
          source: term(),
          required_terms: MapSet.t(String.t()),
          optional_terms: MapSet.t(String.t()),
          negative_terms: MapSet.t(String.t()),
          candidate_groups: [MapSet.t(String.t())],
          verifier: verifier()
        }

  @spec pattern(ExAST.Pattern.pattern()) :: t()
  def pattern(pattern) do
    {required, optional} = partition_terms(Terms.from_pattern(pattern))

    %__MODULE__{
      source: pattern,
      required_terms: required,
      optional_terms: optional,
      verifier: {:pattern, pattern}
    }
  end

  @spec selector(ExAST.Selector.t()) :: t()
  def selector(%ExAST.Selector{} = selector) do
    {positive, negative, candidate_groups} = selector_terms(selector)

    {required, optional} = partition_terms(positive)

    %__MODULE__{
      source: selector,
      required_terms: required,
      optional_terms: optional,
      negative_terms: negative,
      candidate_groups: Enum.map(candidate_groups, &candidate_group_terms/1),
      verifier: {:selector, selector}
    }
  end

  @spec verify(t(), Macro.t()) :: {:ok, [map()]} | :error
  def verify(%__MODULE__{verifier: {:pattern, pattern}}, ast) do
    case ExAST.Pattern.match(ast, pattern) do
      {:ok, captures} -> {:ok, [%{node: ast, captures: captures}]}
      :error -> :error
    end
  end

  def verify(%__MODULE__{verifier: {:selector, selector}}, ast) do
    case ExAST.Patcher.find_all(ast, selector) do
      [] -> :error
      matches -> {:ok, matches}
    end
  end

  def verify(%__MODULE__{verifier: nil}, _ast), do: {:ok, []}

  defp partition_terms(terms) do
    required = Enum.filter(terms, &Terms.high_signal?/1) |> MapSet.new()
    optional = MapSet.difference(terms, required)

    if MapSet.size(required) == 0 do
      {terms, MapSet.new()}
    else
      {required, optional}
    end
  end

  defp selector_terms(%ExAST.Selector{steps: steps, filters: filters}) do
    step_terms =
      steps
      |> Enum.flat_map(fn {_relation, pattern} ->
        Terms.from_pattern(pattern) |> MapSet.to_list()
      end)
      |> MapSet.new()

    Enum.reduce(filters, {step_terms, MapSet.new(), []}, fn filter, {pos, neg, groups} ->
      terms = predicate_terms(filter)

      cond do
        filter.negated? ->
          {pos, MapSet.union(neg, terms), groups}

        filter.relation == :any ->
          {pos, neg, combine_candidate_groups(groups, any_candidate_groups(filter))}

        true ->
          {MapSet.union(pos, terms), neg, groups}
      end
    end)
  end

  defp predicate_terms(%ExAST.Selector.Predicate{relation: :all, pattern: predicates})
       when is_list(predicates) do
    predicates
    |> Enum.map(&predicate_terms/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp predicate_terms(%ExAST.Selector.Predicate{relation: :any, pattern: predicates})
       when is_list(predicates) do
    MapSet.new()
  end

  defp predicate_terms(%ExAST.Selector.Predicate{relation: relation})
       when relation in [:first, :last, :nth],
       do: MapSet.new()

  defp predicate_terms(%ExAST.Selector.Predicate{pattern: pattern}),
    do: Terms.from_pattern(pattern)

  defp any_candidate_groups(%ExAST.Selector.Predicate{relation: :any, pattern: predicates}) do
    Enum.map(predicates, &candidate_group_terms(predicate_terms(&1)))
  end

  defp combine_candidate_groups(existing, new_groups) do
    new_groups = Enum.reject(new_groups, &(MapSet.size(&1) == 0))

    cond do
      new_groups == [] -> existing
      existing == [] -> new_groups
      true -> for left <- existing, right <- new_groups, do: MapSet.union(left, right)
    end
  end

  defp candidate_group_terms(terms) do
    {required, _optional} = partition_terms(terms)
    required
  end
end
