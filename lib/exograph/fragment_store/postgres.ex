defmodule Exograph.FragmentStore.Postgres do
  @moduledoc """
  Durable fragment store backed by Ecto and Postgres.
  """

  @behaviour Exograph.FragmentStore

  import Ecto.Query

  alias Exograph.{Package, PackageVersion, Postgres}

  alias Exograph.Postgres.{
    FileRecord,
    FragmentRecord,
    Options,
    PackageRecord,
    PackageVersionRecord
  }

  defstruct repo: nil, prefix: "exograph", package: nil, package_version: nil

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          package: Package.t() | nil,
          package_version: PackageVersion.t() | nil
        }

  @impl true
  def new(opts \\ []), do: {:ok, Options.store(__MODULE__, opts)}

  @impl true
  def put(%__MODULE__{} = store, fragments) when is_list(fragments) do
    now = DateTime.utc_now(:microsecond)

    upsert_package_context(store, now)
    upsert_files(store, fragments, now)

    entries =
      fragments
      |> Enum.map(fn fragment ->
        fragment
        |> FragmentRecord.from_fragment()
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)
      |> Enum.uniq_by(& &1.id)

    Postgres.bulk_insert_all(
      store.repo,
      {source(store), FragmentRecord},
      entries,
      conflict_target: [:id],
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      timeout: :infinity
    )

    {:ok, store}
  end

  @impl true
  def get(%__MODULE__{} = store, fragment_id) do
    query =
      from(fragment in {source(store), FragmentRecord},
        left_join: file in ^files_source(store),
        on: file.id == fragment.file_id,
        where: fragment.id == ^fragment_id,
        select: {fragment, file.source}
      )

    case store.repo.one(query) do
      {%FragmentRecord{} = record, source} -> {:ok, Options.hydrate_fragment(record, source)}
      nil -> :error
    end
  end

  @impl true
  def all(%__MODULE__{} = store) do
    query =
      from(fragment in {source(store), FragmentRecord},
        left_join: file in ^files_source(store),
        on: file.id == fragment.file_id,
        order_by: [asc: fragment.file, asc: fragment.line, asc: fragment.id],
        select: {fragment, file.source}
      )

    store.repo.all(query)
    |> Enum.map(fn {record, source} -> Options.hydrate_fragment(record, source) end)
  end

  defp upsert_files(_store, [], _now), do: :ok

  defp upsert_files(store, fragments, now) do
    entries =
      fragments
      |> Enum.uniq_by(& &1.file_id)
      |> Enum.reject(&is_nil(&1.file_id))
      |> Enum.map(fn fragment ->
        Exograph.File.new(fragment.file, fragment.source || "", %{
          package_id: fragment.package_id,
          package_version_id: fragment.package_version_id
        })
        |> Map.put(:id, fragment.file_id)
        |> FileRecord.from_file()
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    Postgres.bulk_insert_all(
      store.repo,
      files_source(store),
      entries,
      chunk_size: 500,
      conflict_target: [:id],
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      timeout: :infinity
    )
  end

  defp upsert_package_context(%__MODULE__{package: nil, package_version: nil}, _now), do: :ok

  defp upsert_package_context(%__MODULE__{} = store, now) do
    package = store.package || package_from_version(store.package_version)

    store.repo.insert_all(
      {"#{store.prefix}_packages", PackageRecord},
      [PackageRecord.from_package(package) |> Map.merge(%{inserted_at: now, updated_at: now})],
      conflict_target: [:id],
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      timeout: :infinity
    )

    if store.package_version do
      store.repo.insert_all(
        {"#{store.prefix}_package_versions", PackageVersionRecord},
        [
          PackageVersionRecord.from_package_version(store.package_version)
          |> Map.merge(%{inserted_at: now, updated_at: now})
        ],
        conflict_target: [:id],
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        timeout: :infinity
      )
    end

    :ok
  end

  defp package_from_version(%PackageVersion{} = version) do
    %Package{
      id: version.package_id,
      ecosystem: version.ecosystem,
      name: version.package_name,
      metadata: %{}
    }
  end

  defp files_source(store), do: Options.files_source(store.prefix)
  defp source(store), do: Options.fragments_source(store.prefix)
end
