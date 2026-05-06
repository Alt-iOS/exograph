defmodule Exograph.Postgres.PackageVersionRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Exograph.PackageVersion

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_package_versions" do
    field(:package_id, :string)
    field(:version, :string)
    field(:source_ref, :string)
    field(:checksum, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:id, :package_id, :version, :source_ref, :checksum, :metadata])
    |> validate_required([:id, :package_id, :version])
  end

  def from_package_version(%PackageVersion{} = version) do
    %{
      id: version.id,
      package_id: version.package_id,
      version: version.version,
      source_ref: version.source_ref,
      checksum: version.checksum,
      metadata: version.metadata
    }
  end
end
