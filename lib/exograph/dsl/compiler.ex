defmodule Exograph.DSL.Compiler do
  @moduledoc false

  alias Exograph.DSL.Query

  @spec structural_only?(Query.t()) :: boolean()
  def structural_only?(%Query{source: :fragment, binding: binding, predicates: predicates}) do
    Enum.all?(predicates, fn predicate ->
      match?({_, ^binding, _}, normalize_predicate(predicate)) and
        structural_predicate?(predicate)
    end)
  end

  @spec compile(Query.t()) :: ExAST.Selector.t()
  def compile(%Query{source: :fragment, binding: binding, predicates: predicates}) do
    predicates =
      Enum.filter(predicates, fn predicate ->
        match?({_, ^binding, _}, normalize_predicate(predicate)) and
          structural_predicate?(predicate)
      end)

    {matches, filters} = Enum.split_with(predicates, &match?({:matches, _binding, _pattern}, &1))

    selector =
      case matches do
        [{:matches, _binding, pattern} | _rest] -> ExAST.Query.from(pattern)
        [] -> ExAST.Query.from("_")
      end

    Enum.reduce(filters, selector, fn
      {:contains, _binding, pattern}, selector ->
        ExAST.Selector.where_predicate(selector, ExAST.Query.contains(pattern))
    end)
  end

  defp structural_predicate?({kind, _binding, _value}) when kind in [:matches, :contains],
    do: true

  defp structural_predicate?(_predicate), do: false

  defp normalize_predicate({kind, binding, value}), do: {kind, binding, value}
  defp normalize_predicate({kind, binding, _field, value}), do: {kind, binding, value}
end
