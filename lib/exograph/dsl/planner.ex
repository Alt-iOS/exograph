defmodule Exograph.DSL.Planner do
  @moduledoc false

  alias Exograph.DSL.{Plan, Query}
  alias Exograph.DSL.Plan.Join

  @assoc_sources %{
    definitions: :definition,
    references: :reference,
    calls: :call_edge
  }

  @spec plan(Query.t()) :: Plan.t()
  def plan(%Query{} = query) do
    joins = Enum.with_index(query.joins, 1) |> Enum.map(&join/1)

    %Plan{
      query: query,
      source: query.source,
      binding: query.binding,
      joins: joins,
      predicates_by_binding: Enum.group_by(query.predicates, &predicate_binding/1),
      structural_predicates: Enum.filter(query.predicates, &structural_predicate?/1),
      select: query.select
    }
  end

  defp join({{:assoc, parent, binding, assoc}, position}) do
    %Join{
      parent: parent,
      binding: binding,
      assoc: assoc,
      source: Map.fetch!(@assoc_sources, assoc),
      position: position
    }
  end

  defp predicate_binding({_kind, binding, _value}), do: binding
  defp predicate_binding({_kind, binding, _field, _value}), do: binding
  defp predicate_binding({_kind, binding, _field, _op, _value}), do: binding

  defp structural_predicate?({kind, _binding, _value}) when kind in [:matches, :contains],
    do: true

  defp structural_predicate?(_predicate), do: false
end
