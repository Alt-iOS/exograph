defmodule Mix.Tasks.Exograph.Index.Hex do
  use Mix.Task

  @shortdoc "Index Hex.pm packages into Exograph"

  @moduledoc """
  Downloads and indexes Hex.pm packages into a Postgres-backed Exograph index.

      mix exograph.index.hex
      mix exograph.index.hex --mode top --limit 5000
      mix exograph.index.hex --mode latest --concurrency 8

  Packages are downloaded as tarballs, extracted to a temp directory, indexed,
  then cleaned up. Peak disk usage is proportional to `--concurrency`, not the
  total number of packages.

  Already-indexed packages (by name+version) are skipped by default.
  Use `--force` to re-index everything.

  ## Options

    * `--mode` - `latest` (default), `top`, or `all`
    * `--limit` - max packages to index
    * `--prefix` - table prefix (default: `hex`)
    * `--concurrency` - parallel download+index workers (default: `4`)
    * `--min-mass` - minimum fragment AST mass (default: `8`)
    * `--reach` - include Reach call graph extraction
    * `--force` - re-index already-indexed packages
    * `--bm25` - create ParadeDB BM25 indexes
    * `--mirror` - tarball mirror URL (repeatable)
    * `--cache-tarballs` - directory to cache downloaded tarballs
    * `--database-url` - Postgres URL (or set `EXOGRAPH_DATABASE_URL`)
    * `--repo` - Ecto repo module (uses built-in if omitted)
    * `--timeout` - per-package timeout in seconds (default: `300`)
  """

  @impl true
  def run(args) do
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:req)

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          mode: :string,
          limit: :integer,
          prefix: :string,
          concurrency: :integer,
          min_mass: :integer,
          reach: :boolean,
          force: :boolean,
          bm25: :boolean,
          mirror: :keep,
          cache_tarballs: :string,
          database_url: :string,
          repo: :string,
          timeout: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    repo = resolve_repo(opts)
    mirrors = mirrors_from_opts(opts)

    extractors =
      if Keyword.get(opts, :reach, false), do: [:ex_ast, :reach], else: [:ex_ast]

    corpus_opts = [
      mode: String.to_atom(Keyword.get(opts, :mode, "latest")),
      limit: Keyword.get(opts, :limit),
      prefix: Keyword.get(opts, :prefix, "hex"),
      concurrency: Keyword.get(opts, :concurrency, 4),
      min_mass: Keyword.get(opts, :min_mass, 8),
      resume: not Keyword.get(opts, :force, false),
      bm25?: Keyword.get(opts, :bm25, false),
      extractors: extractors,
      repo: repo,
      mirrors: mirrors,
      mirror_strategy: :round_robin,
      timeout: Keyword.get(opts, :timeout, 300) * 1000,
      cache_dir: Keyword.get(opts, :cache_tarballs)
    ]

    Exograph.Hex.Corpus.index(corpus_opts)
  end

  defp resolve_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        database_url =
          Keyword.get(opts, :database_url) ||
            System.get_env("EXOGRAPH_DATABASE_URL") ||
            "postgres://localhost:5432/postgres"

        {:ok, _} =
          Exograph.Web.Repo.start_link(
            url: database_url,
            pool_size: 10,
            log: false,
            timeout: 120_000
          )

        Exograph.Web.Repo

      repo_str ->
        Mix.Task.run("app.start")
        Module.concat([repo_str])
    end
  end

  defp mirrors_from_opts(opts) do
    case Keyword.get_values(opts, :mirror) do
      [] -> ["https://repo.hex.pm"]
      mirrors -> mirrors
    end
  end
end
