defmodule Exograph.Postgres.GraphNodeRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.GraphNode

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_graph_nodes" do
    field(:package_id, :string)
    field(:package_version_id, :string)
    field(:file_id, :string)
    field(:fragment_id, :string)
    field(:engine, :string)
    field(:external_id, :string)
    field(:kind, Ecto.Enum, values: [:function, :external_function])
    field(:module, :string)
    field(:name, :string)
    field(:arity, :integer)
    field(:qualified_name, :string)
    field(:line, :integer)
    field(:column, :integer)
    field(:metadata, :map)

    timestamps(type: :utc_datetime_usec)
  end

  def from_graph_node(%GraphNode{} = node) do
    Map.take(node, [
      :id,
      :package_id,
      :package_version_id,
      :file_id,
      :fragment_id,
      :engine,
      :external_id,
      :kind,
      :module,
      :name,
      :arity,
      :qualified_name,
      :line,
      :column,
      :metadata
    ])
  end
end
