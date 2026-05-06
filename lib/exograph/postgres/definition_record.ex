defmodule Exograph.Postgres.DefinitionRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.Definition

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_definitions" do
    field(:package_id, :string)
    field(:package_version_id, :string)
    field(:file_id, :string)
    field(:fragment_id, :string)

    field(:kind, Ecto.Enum,
      values: [
        :module,
        :def,
        :defp,
        :defmacro,
        :defmacrop,
        :defdelegate,
        :defcallback,
        :defmacrocallback,
        :attribute
      ]
    )

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

  def from_definition(%Definition{} = definition) do
    Map.take(definition, [
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
    ])
  end
end
