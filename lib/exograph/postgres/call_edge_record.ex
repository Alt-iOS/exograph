defmodule Exograph.Postgres.CallEdgeRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.CallEdge

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_call_edges" do
    field(:package_id, :string)
    field(:package_version_id, :string)
    field(:file_id, :string)
    field(:caller_node_id, :string)
    field(:callee_node_id, :string)
    field(:call_site_fragment_id, :string)
    field(:caller_qualified_name, :string)
    field(:callee_qualified_name, :string)
    field(:line, :integer)
    field(:column, :integer)
    field(:metadata, :map)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
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
    :metadata
  ]

  def from_call_edge(%CallEdge{} = edge), do: Map.take(edge, @fields)

  def to_call_edge(%__MODULE__{} = record) do
    struct(CallEdge, Map.take(record, @fields))
  end
end
