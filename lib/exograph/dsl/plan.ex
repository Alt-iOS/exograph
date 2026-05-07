defmodule Exograph.DSL.Plan do
  @moduledoc false

  @type join :: Exograph.DSL.Plan.Join.t()

  @type t :: %__MODULE__{
          query: Exograph.DSL.Query.t(),
          source: Exograph.DSL.Query.source(),
          binding: atom(),
          joins: [join()],
          predicates_by_binding: %{atom() => [Exograph.DSL.Query.predicate()]},
          structural_predicates: [Exograph.DSL.Query.predicate()],
          select: Exograph.DSL.Query.select()
        }

  defstruct [
    :query,
    :source,
    :binding,
    :select,
    joins: [],
    predicates_by_binding: %{},
    structural_predicates: []
  ]
end
