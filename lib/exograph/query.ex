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
    positive = MapSet.union(positive, inferred_capture_terms(selector))

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

  @spec requires_source?(t()) :: boolean()
  def requires_source?(%__MODULE__{source: %ExAST.Selector{} = selector}),
    do: source_required?(selector)

  def requires_source?(_query), do: false

  @spec comment_texts(t()) :: [String.t()]
  def comment_texts(%__MODULE__{source: %ExAST.Selector{filters: filters}}) do
    filters
    |> Enum.flat_map(&comment_texts_from_predicate/1)
    |> Enum.uniq()
  end

  def comment_texts(_query), do: []

  @spec verify(t(), Macro.t() | Exograph.Fragment.t()) :: {:ok, [map()]} | :error
  def verify(%__MODULE__{verifier: {:pattern, pattern}}, %{ast: ast}) do
    verify(%__MODULE__{verifier: {:pattern, pattern}}, ast)
  end

  def verify(%__MODULE__{verifier: {:pattern, pattern}}, ast) do
    case ExAST.Pattern.match(ast, pattern) do
      {:ok, captures} -> {:ok, [%{node: ast, captures: captures}]}
      :error -> :error
    end
  end

  def verify(%__MODULE__{verifier: {:selector, selector}}, %{source: source, ast: ast}) do
    cond do
      simple_self_capture_selector?(selector) ->
        verify_simple_self_capture(selector, ast)

      source_required?(selector) ->
        verify_selector(source || ast, selector)

      true ->
        verify_selector(ast, selector)
    end
  end

  def verify(%__MODULE__{verifier: {:selector, selector}}, ast) do
    if simple_self_capture_selector?(selector) do
      verify_simple_self_capture(selector, ast)
    else
      verify_selector(ast, selector)
    end
  end

  def verify(%__MODULE__{verifier: nil}, _ast), do: {:ok, []}

  defp verify_selector(input, selector) do
    case ExAST.Patcher.find_all(input, selector) do
      [] -> :error
      matches -> {:ok, matches}
    end
  end

  defp verify_simple_self_capture(
         %ExAST.Selector{steps: [self: pattern], filters: filters},
         ast
       ) do
    {_ast, matches} =
      Macro.prewalk(ast, [], fn node, matches ->
        case ExAST.Pattern.match(node, pattern) do
          {:ok, captures} ->
            if Enum.all?(filters, &capture_predicate?(&1, captures)) do
              {node, [%{node: node, range: nil, source: nil, captures: captures} | matches]}
            else
              {node, matches}
            end

          :error ->
            {node, matches}
        end
      end)

    case Enum.reverse(matches) do
      [] -> :error
      matches -> {:ok, matches}
    end
  end

  defp simple_self_capture_selector?(%ExAST.Selector{steps: [self: _pattern], filters: filters}) do
    Enum.all?(filters, fn
      %ExAST.Selector.Predicate{relation: :captures, pattern: fun} -> is_function(fun, 1)
      _predicate -> false
    end)
  end

  defp simple_self_capture_selector?(_selector), do: false

  defp capture_predicate?(%ExAST.Selector.Predicate{relation: :captures, pattern: fun}, captures) do
    fun.(captures)
  end

  defp comment_texts_from_predicate(%ExAST.Selector.Predicate{pattern: predicates})
       when is_list(predicates),
       do: Enum.flat_map(predicates, &comment_texts_from_predicate/1)

  defp comment_texts_from_predicate(%ExAST.Selector.Predicate{
         relation: relation,
         pattern: %ExAST.Selector.CommentMatcher{kind: :text, value: value}
       })
       when relation in [
              :comment,
              :comment_before,
              :comment_after,
              :comment_inside,
              :comment_inline
            ],
       do: [value]

  defp comment_texts_from_predicate(_predicate), do: []

  defp source_required?(%ExAST.Selector{filters: filters}) do
    Enum.any?(filters, &source_required_predicate?/1)
  end

  defp source_required_predicate?(%ExAST.Selector.Predicate{relation: relation})
       when relation in [
              :comment,
              :comment_before,
              :comment_after,
              :comment_inside,
              :comment_inline
            ],
       do: true

  defp source_required_predicate?(%ExAST.Selector.Predicate{pattern: predicates})
       when is_list(predicates),
       do: Enum.any?(predicates, &source_required_predicate?/1)

  defp source_required_predicate?(_predicate), do: false

  defp inferred_capture_terms(%ExAST.Selector{
         steps: [self: {op, _meta, [left, right]}],
         filters: filters
       })
       when is_atom(op) do
    if equality_capture_guard?(filters, left, right) do
      MapSet.new(["call.local.same_args:#{op}/2"])
    else
      MapSet.new()
    end
  end

  defp inferred_capture_terms(_selector), do: MapSet.new()

  defp equality_capture_guard?(filters, left, right) do
    left_name = capture_name(left)
    right_name = capture_name(right)

    left_name && right_name &&
      Enum.any?(filters, &same_capture_predicate?(&1, left_name, right_name))
  end

  defp same_capture_predicate?(
         %ExAST.Selector.Predicate{relation: :captures, pattern: fun},
         left,
         right
       )
       when is_function(fun, 1) do
    same = %{left => {:__exograph_same__, [], nil}, right => {:__exograph_same__, [], nil}}
    different = %{left => {:__exograph_left__, [], nil}, right => {:__exograph_right__, [], nil}}

    fun.(same) == true and fun.(different) == false
  end

  defp same_capture_predicate?(_predicate, _left, _right), do: false

  defp capture_name({name, _meta, nil}) when is_atom(name), do: name
  defp capture_name(_ast), do: nil

  defp partition_terms(terms) do
    high_signal = Enum.filter(terms, &Terms.high_signal?/1) |> MapSet.new()
    indexable = Enum.reject(terms, &low_signal?/1) |> MapSet.new()

    cond do
      MapSet.size(high_signal) > 0 -> {high_signal, MapSet.difference(indexable, high_signal)}
      MapSet.size(indexable) > 0 -> {indexable, MapSet.new()}
      true -> {MapSet.new(), MapSet.new()}
    end
  end

  defp low_signal?("atom:" <> atom), do: atom in ["do", "nil", "true", "false", "ok", "error"]
  defp low_signal?("node:call"), do: true
  defp low_signal?("node:local_call"), do: true
  defp low_signal?("node:remote_call"), do: true
  defp low_signal?("call.arity:" <> _), do: true
  defp low_signal?("call.local:./2"), do: true
  defp low_signal?("call.function:."), do: true
  defp low_signal?(_term), do: false

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
       when relation in [
              :first,
              :last,
              :nth,
              :captures,
              :comment,
              :comment_before,
              :comment_after,
              :comment_inside,
              :comment_inline
            ],
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
