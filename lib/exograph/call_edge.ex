defmodule Exograph.CallEdge do
  @moduledoc "Reach-derived call graph edge."

  @type t :: %__MODULE__{
          id: integer() | nil,
          package_id: integer() | nil,
          package_version_id: integer() | nil,
          file_id: integer() | nil,
          caller_node_id: integer(),
          callee_node_id: integer(),
          call_site_fragment_id: integer() | nil,
          caller_qualified_name: String.t(),
          callee_qualified_name: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :caller_node_id,
    :callee_node_id,
    :call_site_fragment_id,
    :caller_qualified_name,
    :callee_qualified_name,
    :line,
    :column,
    metadata: %{}
  ]

  def new(attrs) do
    struct(__MODULE__, Map.new(attrs))
  end
end
