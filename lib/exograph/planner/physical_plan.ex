defmodule Exograph.Planner.PhysicalPlan do
  @moduledoc """
  Executable scan/filter plan chosen for a logical query.
  """

  @type scan ::
          :fragment_seq_scan
          | {:term_index_scan, [String.t()]}
          | {:union_term_index_scan, [[String.t()]]}
  @type filter :: :hydrate_fragments | :ex_ast_verify

  @type t :: %__MODULE__{
          scan: scan(),
          filters: [filter()],
          limit: pos_integer(),
          verify?: boolean(),
          fallback?: boolean()
        }

  defstruct scan: :fragment_seq_scan,
            filters: [:hydrate_fragments, :ex_ast_verify],
            limit: 50,
            verify?: true,
            fallback?: false
end
