defmodule Exograph.DSL.Compiler do
  @moduledoc false

  alias Exograph.DSL.Query

  @spec compile(Query.t()) :: ExAST.Selector.t()
  def compile(%Query{source: :fragment, predicates: predicates}) do
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
end
