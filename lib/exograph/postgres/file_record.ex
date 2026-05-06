defmodule Exograph.Postgres.FileRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.File

  @primary_key {:id, :string, autogenerate: false}
  schema "exograph_files" do
    field(:package_id, :string)
    field(:package_version_id, :string)
    field(:path, :string)
    field(:source, :string)
    field(:sha256, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def from_file(%File{} = file) do
    %{
      id: file.id,
      package_id: file.package_id,
      package_version_id: file.package_version_id,
      path: file.path,
      source: file.source,
      sha256: file.sha256
    }
  end
end
