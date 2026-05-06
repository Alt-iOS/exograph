defmodule Exograph.FragmentStore.Postgres do
  @moduledoc """
  Durable fragment store backed by Ecto and Postgres.
  """

  @behaviour Exograph.FragmentStore

  import Ecto.Query

  alias Exograph.{Package, PackageVersion, Postgres}
  alias Exograph.Postgres.{FragmentRecord, PackageRecord, PackageVersionRecord}

  defstruct repo: nil, prefix: "exograph", package: nil, package_version: nil

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          package: Package.t() | nil,
          package_version: PackageVersion.t() | nil
        }

  @impl true
  def new(opts \\ []) do
    if Keyword.get(opts, :migrate?, false), do: Postgres.migrate!(opts)

    {:ok,
     %__MODULE__{
       repo: Postgres.fetch_repo!(opts),
       prefix: Keyword.get(opts, :prefix, "exograph"),
       package: package(opts),
       package_version: package_version(opts)
     }}
  end

  @impl true
  def put(%__MODULE__{} = store, fragments) when is_list(fragments) do
    now = DateTime.utc_now(:microsecond)

    upsert_package_context(store, now)

    entries =
      fragments
      |> Enum.map(fn fragment ->
        fragment
        |> FragmentRecord.from_fragment()
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)
      |> Enum.uniq_by(& &1.id)

    entries
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      store.repo.insert_all(
        {source(store), FragmentRecord},
        chunk,
        conflict_target: [:id],
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        timeout: :infinity
      )
    end)

    {:ok, store}
  end

  @impl true
  def get(%__MODULE__{} = store, fragment_id) do
    case store.repo.get({source(store), FragmentRecord}, fragment_id) do
      %FragmentRecord{} = record -> {:ok, FragmentRecord.to_fragment(record)}
      nil -> :error
    end
  end

  @impl true
  def all(%__MODULE__{} = store) do
    query =
      from(fragment in {source(store), FragmentRecord},
        order_by: [asc: fragment.file, asc: fragment.line, asc: fragment.id]
      )

    store.repo.all(query)
    |> Enum.map(&FragmentRecord.to_fragment/1)
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

  defp package(opts) do
    case Keyword.get(opts, :package) do
      nil -> nil
      %Package{} = package -> package
      attrs -> Package.new(attrs)
    end
  end

  defp package_version(opts) do
    case Keyword.get(opts, :package_version) do
      nil -> nil
      %PackageVersion{} = version -> version
      attrs -> PackageVersion.new(attrs)
    end
  end

  defp package_from_version(%PackageVersion{} = version) do
    %Package{
      id: version.package_id,
      ecosystem: version.ecosystem,
      name: version.package_name,
      metadata: %{}
    }
  end

  defp source(store), do: "#{store.prefix}_fragments"
end
