defmodule Mix.Tasks.Exograph.Index do
  use Mix.Task

  @shortdoc "Indexes an Elixir codebase with Exograph"

  @moduledoc """
  Indexes Elixir source files with Exograph.

      mix exograph.index
      mix exograph.index lib test
      mix exograph.index --backend memory lib
      mix exograph.index --backend postgres --repo MyApp.Repo --migrate lib
      mix exograph.index --backend tantivy --index-path .exograph/tantivy lib
      mix exograph.index --min-mass 8 --stats lib

  ## Options

    * `--backend` - `memory`, `postgres`, or `tantivy` (default: `memory`)
    * `--repo` - Ecto repo module for the Postgres backend
    * `--prefix` - Exograph table prefix for the Postgres backend (default: `exograph`)
    * `--migrate` - create/upgrade Postgres tables and ParadeDB BM25 index
    * `--no-bm25` - skip ParadeDB `pg_search` extension/index creation during migration
    * `--index-path` - Tantivy index directory (default: `.exograph/tantivy`)
    * `--min-mass` - minimum AST fragment mass (default: `8`)
    * `--stats` - print indexed fragment statistics
    * `--json` - print summary as JSON

  The memory backend is useful for smoke-testing indexing. Postgres is the
  primary durable backend; with ParadeDB `pg_search` installed, `--migrate`
  creates a Tantivy-powered BM25 covering index inside Postgres.
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [
          backend: :string,
          index_path: :string,
          repo: :string,
          prefix: :string,
          migrate: :boolean,
          no_bm25: :boolean,
          min_mass: :integer,
          stats: :boolean,
          json: :boolean
        ],
        aliases: [b: :backend, o: :index_path]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    paths = if paths == [], do: ["lib"], else: paths
    backend_name = Keyword.get(opts, :backend, "memory")
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

        fragments = index.fragment_store_backend.all(index.fragment_store)
        summary = summary(paths, backend_name, backend_opts, fragments, elapsed_ms)

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

  defp backend_opts("memory", _opts), do: []

  defp backend_opts("postgres", opts) do
    [
      repo: repo!(opts),
      prefix: Keyword.get(opts, :prefix, "exograph"),
      migrate?: Keyword.get(opts, :migrate, false),
      bm25?: !Keyword.get(opts, :no_bm25, false)
    ]
  end

  defp backend_opts("tantivy", opts) do
    [index_path: Keyword.get(opts, :index_path, ".exograph/tantivy")]
  end

  defp backend_opts(other, _opts) do
    Mix.raise("Unknown backend #{inspect(other)}. Expected: memory, postgres, or tantivy")
  end

  defp repo!(opts) do
    opts
    |> Keyword.fetch!(:repo)
    |> String.split(".")
    |> Module.concat()
  end

  defp summary(paths, backend_name, backend_opts, fragments, elapsed_ms) do
    files = fragments |> Enum.map(& &1.file) |> Enum.uniq()

    %{
      paths: paths,
      backend: backend_name,
      index_path: Keyword.get(backend_opts, :index_path),
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

    if summary.index_path do
      Mix.shell().info("Index path: #{summary.index_path}")
    end
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

  defp json(value) do
    if Code.ensure_loaded?(Jason) do
      Jason.encode!(value)
    else
      inspect(value, limit: :infinity)
    end
  end
end
