defmodule Exograph.Postgres.ReferenceRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.Reference

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_references" do
    field(:package_id, :string)
    field(:package_version_id, :string)
    field(:file_id, :string)
    field(:fragment_id, :string)
    field(:kind, Ecto.Enum, values: [:local_call, :remote_call, :alias, :module_attribute])
    field(:module, :string)
    field(:name, :string)
    field(:arity, :integer)
    field(:qualified_name, :string)
    field(:mfa_module, :string)
    field(:mfa_name, :string)
    field(:mfa_arity, :integer)
    field(:line, :integer)
    field(:column, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :fragment_id,
    :kind,
    :module,
    :name,
    :arity,
    :qualified_name,
    :mfa_module,
    :mfa_name,
    :mfa_arity,
    :line,
    :column
  ]

  def from_reference(%Reference{} = reference), do: Map.take(reference, @fields)

  def to_reference(%__MODULE__{} = record) do
    struct(Reference, Map.take(record, @fields))
  end
end
