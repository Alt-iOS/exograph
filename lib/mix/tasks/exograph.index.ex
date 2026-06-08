defmodule Mix.Tasks.Exograph.Index do
  use Mix.Task

  @shortdoc "Indexes an Elixir codebase with Exograph"

  @moduledoc """
  Indexes Elixir source files with Exograph.

      mix exograph.index --repo MyApp.Repo --migrate
      mix exograph.index --repo MyApp.Repo --migrate lib test
      mix exograph.index --repo MyApp.Repo --min-mass 8 --stats lib

  ## Options

    * `--backend` - `duckdb` (default) or `postgres`
    * `--repo` - Ecto repo module for the selected backend
    * `--prefix` - Exograph table prefix (default: `exograph`)
    * `--migrate` - create/upgrade backend tables and text indexes
    * `--no-bm25` - skip BM25/full-text index creation during migration/finalization
    * `--quackdb-uri` - QuackDB URI for the DuckDB backend when `--repo` is omitted
    * `--quackdb-token` - QuackDB token for the DuckDB backend
    * `--duckdb-database` - managed DuckDB database path when `--quackdb-uri` is omitted
    * `--duckdb-threads` - DuckDB execution threads for indexing/query setup
    * `--postgres-maintenance-work-mem` - session-local maintenance_work_mem during Postgres index builds
    * `--postgres-max-parallel-maintenance-workers` - session-local max_parallel_maintenance_workers during Postgres index builds
    * `--postgres-unlogged` - use UNLOGGED Postgres tables for rebuildable local indexes
    * `--min-mass` - minimum AST fragment mass (default: `8`)
    * `--stats` - print indexed fragment statistics
    * `--json` - print summary as JSON

  DuckDB/QuackDB is recommended for local indexes and fast query latency.
  Postgres remains supported for server deployments and ParadeDB-backed BM25.
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [
          backend: :string,
          repo: :string,
          prefix: :string,
          migrate: :boolean,
          no_bm25: :boolean,
          quackdb_uri: :string,
          quackdb_token: :string,
          duckdb_database: :string,
          duckdb_threads: :integer,
          postgres_maintenance_work_mem: :string,
          postgres_max_parallel_maintenance_workers: :integer,
          postgres_unlogged: :boolean,
          min_mass: :integer,
          stats: :boolean,
          json: :boolean
        ],
        aliases: [b: :backend]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    paths = if paths == [], do: ["lib"], else: paths
    backend_name = Keyword.get(opts, :backend, Mix.Exograph.BackendOptions.default_backend())
    min_mass = Keyword.get(opts, :min_mass, 8)

    backend_opts = backend_opts(backend_name, opts)

    started_at = System.monotonic_time()

    case Exograph.index(
           paths,
           Keyword.merge(
             [backend: String.to_existing_atom(backend_name), min_mass: min_mass],
             backend_opts
           )
         ) do
      {:ok, index} ->
        elapsed_ms =
          System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

        fragments = Exograph.Storage.Ecto.FragmentStore.all(index.fragment_store)
        summary = summary(paths, backend_name, fragments, elapsed_ms)

        if Keyword.get(opts, :json, false) do
          Mix.shell().info(json(summary))
        else
          print_summary(summary)
          if Keyword.get(opts, :stats, false), do: print_stats(fragments)
        end

      {:error, reason} ->
        Mix.raise("Failed to index codebase: #{inspect(reason)}")
    end
  end

  defp backend_opts(backend, opts), do: Mix.Exograph.BackendOptions.backend_opts(backend, opts)

  defp summary(paths, backend_name, fragments, elapsed_ms) do
    files = fragments |> Enum.map(& &1.file) |> Enum.uniq()

    %{
      paths: paths,
      backend: backend_name,
      files: length(files),
      fragments: length(fragments),
      elapsed_ms: elapsed_ms,
      by_kind: count_by(fragments, & &1.kind)
    }
  end

  defp print_summary(summary) do
    Mix.shell().info(
      "Indexed #{summary.fragments} fragments from #{summary.files} files in #{summary.elapsed_ms}ms"
    )

    Mix.shell().info("Backend: #{summary.backend}")
  end

  defp print_stats(fragments) do
    Mix.shell().info("")
    Mix.shell().info("Fragments by kind:")

    fragments
    |> count_by(& &1.kind)
    |> Enum.sort_by(fn {_kind, count} -> count end, :desc)
    |> Enum.each(fn {kind, count} -> Mix.shell().info("  #{kind}: #{count}") end)

    Mix.shell().info("")
    Mix.shell().info("Top files:")

    fragments
    |> count_by(& &1.file)
    |> Enum.sort_by(fn {_file, count} -> count end, :desc)
    |> Enum.take(10)
    |> Enum.each(fn {file, count} -> Mix.shell().info("  #{file}: #{count}") end)
  end

  defp count_by(items, fun) do
    Enum.reduce(items, %{}, fn item, acc ->
      key = fun.(item)
      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  defp json(value), do: JSON.encode!(value)
end
