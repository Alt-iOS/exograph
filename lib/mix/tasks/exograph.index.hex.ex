defmodule Mix.Tasks.Exograph.Index.Hex do
  use Mix.Task

  @shortdoc "Index Hex.pm packages into Exograph"

  @moduledoc """
  Downloads and indexes Hex.pm packages into a DuckDB/QuackDB-backed Exograph index by default.

      mix exograph.index.hex
      mix exograph.index.hex --mode top --limit 5000
      mix exograph.index.hex --mode latest --concurrency 8
      mix exograph.index.hex --mode latest --web --port 4200

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
    * `--duckdb-shards` - shard count for DuckDB corpus indexing (recommended for large corpora)
    * `--duckdb-threads` - DuckDB execution threads per shard/server
    * `--duckdb-recovery-mode` - DuckDB managed-server recovery mode (`no_wal_writes` for rebuildable indexes)
    * `--manifest-path` - write a sharded DuckDB manifest to this path
    * `--shard-dir` - directory for managed DuckDB shard files
    * `--min-mass` - minimum fragment AST mass (default: `8`)
    * `--reach` - include Reach call graph extraction
    * `--force` - re-index already-indexed packages
    * `--no-bm25` - skip ParadeDB BM25 index creation
    * `--mirror` - tarball mirror URL (repeatable)
    * `--cache-tarballs` - directory to cache downloaded tarballs
    * `--backend` - `duckdb` (default) or `postgres`
    * `--database-url` - Postgres URL (or set `EXOGRAPH_DATABASE_URL`)
    * `--quackdb-uri` - QuackDB URI for DuckDB backend (or set `QUACKDB_URI` / `QUACKDB_TEST_URI`)
    * `--quackdb-token` - QuackDB token for DuckDB backend (or set `QUACKDB_TOKEN` / `QUACKDB_TEST_TOKEN`)
    * `--duckdb-database` - managed DuckDB database path when `--quackdb-uri` is omitted
    * `--repo` - Ecto repo module (uses built-in if omitted)
    * `--timeout` - per-package timeout in seconds (default: `300`)
    * `--web` - start web UI with live progress dashboard
    * `--port` - web UI port (default: `4200`, requires `--web`)
  """

  @impl true
  def run(args) do
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:req)

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          backend: :string,
          mode: :string,
          limit: :integer,
          prefix: :string,
          concurrency: :integer,
          duckdb_shards: :integer,
          duckdb_threads: :integer,
          duckdb_recovery_mode: :string,
          manifest_path: :string,
          shard_dir: :string,
          min_mass: :integer,
          reach: :boolean,
          force: :boolean,
          no_bm25: :boolean,
          mirror: :keep,
          cache_tarballs: :string,
          database_url: :string,
          quackdb_uri: :string,
          quackdb_token: :string,
          duckdb_database: :string,
          repo: :string,
          timeout: :integer,
          web: :boolean,
          port: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    backend = backend!(Keyword.get(opts, :backend, Mix.Exograph.BackendOptions.default_backend()))
    repo = resolve_repo(backend, opts)
    prefix = Keyword.get(opts, :prefix, "hex")

    Exograph.Hex.Progress.start_link()

    if Keyword.get(opts, :web, false) do
      start_web!(backend, repo, prefix, opts)
    end

    mirrors = mirrors_from_opts(opts)

    extractors =
      if Keyword.get(opts, :reach, false), do: [:ex_ast, :reach], else: [:ex_ast]

    corpus_opts = [
      backend: backend,
      mode: String.to_atom(Keyword.get(opts, :mode, "latest")),
      limit: Keyword.get(opts, :limit),
      prefix: prefix,
      concurrency: Keyword.get(opts, :concurrency, 4),
      shards: Keyword.get(opts, :duckdb_shards, 1),
      duckdb_threads: Keyword.get(opts, :duckdb_threads),
      recovery_mode: recovery_mode(Keyword.get(opts, :duckdb_recovery_mode)),
      manifest_path: Keyword.get(opts, :manifest_path),
      shard_directory: Keyword.get(opts, :shard_dir),
      min_mass: Keyword.get(opts, :min_mass, 8),
      resume: not Keyword.get(opts, :force, false),
      bm25?: !Keyword.get(opts, :no_bm25, false),
      extractors: extractors,
      repo: repo,
      mirrors: mirrors,
      mirror_strategy: :round_robin,
      timeout: Keyword.get(opts, :timeout, 300) * 1000,
      cache_dir: Keyword.get(opts, :cache_tarballs)
    ]

    Exograph.Hex.Corpus.index(corpus_opts)

    if Keyword.get(opts, :web, false) do
      Mix.shell().info(["\nIndexing complete. Web UI still running. Press Ctrl+C to stop."])
      unless iex_running?(), do: Process.sleep(:infinity)
    end
  end

  defp iex_running?, do: Code.ensure_loaded?(IEx) and IEx.started?()

  defp backend!("postgres"), do: :postgres
  defp backend!("duckdb"), do: :duckdb
  defp backend!(backend), do: Mix.raise("Unknown backend #{inspect(backend)}")

  defp recovery_mode(nil), do: nil
  defp recovery_mode("no_wal_writes"), do: :no_wal_writes
  defp recovery_mode(value), do: Mix.raise("Unknown DuckDB recovery mode #{inspect(value)}")

  defp resolve_repo(:postgres, opts) do
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

  defp resolve_repo(:duckdb, opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        Application.ensure_all_started(:ecto_sql)
        Application.ensure_all_started(:quackdb)

        if Keyword.get(opts, :duckdb_shards, 1) <= 1 do
          Application.put_env(:exograph, Exograph.DuckDBRepo,
            uri:
              Keyword.get(opts, :quackdb_uri) || System.get_env("QUACKDB_URI") ||
                System.get_env("QUACKDB_TEST_URI") || start_managed_duckdb!(opts),
            token: duckdb_token(opts),
            pool_size: Keyword.get(opts, :concurrency, 4),
            telemetry_prefix: [:quackdb],
            log: false,
            timeout: 120_000
          )

          {:ok, _} = Exograph.DuckDBRepo.start_link()
        end

        Exograph.DuckDBRepo

      repo_str ->
        Mix.Task.run("app.start")
        Module.concat([repo_str])
    end
  end

  defp start_managed_duckdb!(opts) do
    token = duckdb_token(opts)
    endpoint = "quack:localhost:#{free_tcp_port!()}"

    server_opts =
      [
        duckdb: :managed,
        database:
          Keyword.get(opts, :duckdb_database, "#{Keyword.get(opts, :prefix, "hex")}.duckdb"),
        endpoint: endpoint,
        token: token,
        settings: duckdb_settings(Keyword.get(opts, :duckdb_threads))
      ]
      |> put_optional(:recovery_mode, recovery_mode(Keyword.get(opts, :duckdb_recovery_mode)))

    {:ok, server} = QuackDB.Server.start_link(server_opts)

    QuackDB.Server.uri(server)
  end

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp duckdb_token(opts) do
    Keyword.get(opts, :quackdb_token) || System.get_env("QUACKDB_TOKEN") ||
      System.get_env("QUACKDB_TEST_TOKEN") || "exograph"
  end

  defp duckdb_settings(nil), do: [threads: System.schedulers_online()]
  defp duckdb_settings(threads), do: [threads: threads]

  defp free_tcp_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp start_web!(backend, repo, prefix, opts) do
    port = Keyword.get(opts, :port, 4200)

    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:phoenix_live_view)

    {:ok, index} =
      Exograph.index([],
        backend: backend,
        repo: repo,
        prefix: prefix,
        migrate?: false,
        bm25?: !Keyword.get(opts, :no_bm25, false)
      )

    Application.put_env(:exograph, :web_index, index)
    Application.put_env(:exograph, :web_repo, repo)
    Application.put_env(:exograph, :web_prefix, prefix)

    Exograph.Web.Server.put_endpoint_config(port)

    Exograph.Web.Monaco.ensure_bundled!()
    Mix.Task.rerun("volt.build")

    if Code.ensure_loaded?(Hammer), do: Exograph.Web.RateLimiter.start_link([])

    {:ok, _} = Exograph.Web.Server.start_pubsub_and_endpoint!()

    Mix.shell().info([
      "Progress dashboard at ",
      IO.ANSI.cyan(),
      "http://localhost:#{port}/progress",
      IO.ANSI.reset()
    ])
  end

  defp mirrors_from_opts(opts) do
    case Keyword.get_values(opts, :mirror) do
      [] -> ["https://repo.hex.pm"]
      mirrors -> mirrors
    end
  end
end
