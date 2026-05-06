defmodule Exograph.Postgres.PackageRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Exograph.Package

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_packages" do
    field(:ecosystem, :string)
    field(:name, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:id, :ecosystem, :name, :metadata])
    |> validate_required([:id, :ecosystem, :name])
  end

  def from_package(%Package{} = package) do
    %{
      id: package.id,
      ecosystem: to_string(package.ecosystem),
      name: package.name,
      metadata: package.metadata
    }
  end
end
