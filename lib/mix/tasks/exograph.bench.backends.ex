defmodule Mix.Tasks.Exograph.Bench.Backends do
  use Mix.Task

  @shortdoc "Compare Postgres and DuckDB indexing/query speed"

  @moduledoc """
  Benchmarks Exograph indexing and query speed across Postgres and DuckDB using
  the same Hex.pm package workload.

      mix exograph.bench.backends --mode top --limit 20 --iterations 10
      mix exograph.bench.backends --mode top --limit 100 --runs 3 --order random --output-json bench.json
      mix exograph.bench.backends --mode top --limit 20 --concurrency 4 --duckdb-threads 1
      mix exograph.bench.backends --mode top --limit 20 --duckdb-shards 4 --duckdb-threads 1
      mix exograph.bench.backends --mode top --limit 100 --duckdb-shards 8 --duckdb-threads 1 --duckdb-recovery-mode no_wal_writes --postgres-maintenance-work-mem 1GB --postgres-max-parallel-maintenance-workers 4 --postgres-copy --postgres-unlogged --postgres-defer-indexes --postgres-synchronous-commit off --only postgres_plain,duckdb_plain,duckdb_sharded_plain --order random --append-metrics --output-json bench.json

  Required services:

    * Postgres: `EXOGRAPH_DATABASE_URL` or `--database-url`
    * DuckDB: `QUACKDB_URI` / `QUACKDB_TEST_URI` or `--quackdb-uri`
    * Sharded DuckDB starts managed QuackDB servers and can use `--duckdb-recovery-mode no_wal_writes`
    * `--only` can restrict variants, for example `postgres_plain,duckdb_plain,duckdb_sharded_plain`
    * Prefixes are dropped after each run by default; use `--keep-prefixes` to inspect tables manually.
    * `--explain-dir path` writes Postgres `EXPLAIN (ANALYZE, BUFFERS)` plans before cleanup.

  The benchmark uses fresh prefixes and reports separate plain and BM25 variants:
  `postgres_plain`, `postgres_bm25`, `duckdb_plain`, and `duckdb_bm25`.
  """

  @tables ~w(tree_nodes call_edges graph_nodes references definitions comments fragments fragment_terms terms files package_versions packages schema_migrations)

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:ecto_sql)

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          mode: :string,
          limit: :integer,
          concurrency: :integer,
          index_concurrency: :integer,
          iterations: :integer,
          warmup: :integer,
          runs: :integer,
          min_mass: :integer,
          cache_tarballs: :string,
          database_url: :string,
          quackdb_uri: :string,
          quackdb_token: :string,
          duckdb_threads: :integer,
          duckdb_shards: :integer,
          duckdb_recovery_mode: :string,
          postgres_maintenance_work_mem: :string,
          postgres_max_parallel_maintenance_workers: :integer,
          postgres_unlogged: :boolean,
          postgres_defer_indexes: :boolean,
          postgres_copy: :boolean,
          postgres_synchronous_commit: :string,
          append_metrics: :boolean,
          order: :string,
          only: :string,
          timeout: :integer,
          output_json: :string,
          keep_prefixes: :boolean,
          explain_dir: :string
        ]
      )

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    config = %{
      mode: opts |> Keyword.get(:mode, "top") |> String.to_atom(),
      limit: Keyword.get(opts, :limit, 20),
      concurrency: Keyword.get(opts, :concurrency, 1),
      index_concurrency: Keyword.get(opts, :index_concurrency),
      iterations: Keyword.get(opts, :iterations, 10),
      warmup: Keyword.get(opts, :warmup, 2),
      runs: Keyword.get(opts, :runs, 1),
      min_mass: Keyword.get(opts, :min_mass, 8),
      timeout: Keyword.get(opts, :timeout, 300) * 1000,
      cache_dir: Keyword.get(opts, :cache_tarballs),
      duckdb_threads: Keyword.get(opts, :duckdb_threads),
      duckdb_shards: Keyword.get(opts, :duckdb_shards, 0),
      duckdb_recovery_mode: recovery_mode(Keyword.get(opts, :duckdb_recovery_mode)),
      postgres_maintenance_work_mem: Keyword.get(opts, :postgres_maintenance_work_mem),
      postgres_max_parallel_maintenance_workers:
        Keyword.get(opts, :postgres_max_parallel_maintenance_workers),
      postgres_unlogged?: Keyword.get(opts, :postgres_unlogged, false),
      postgres_defer_indexes?: Keyword.get(opts, :postgres_defer_indexes, false),
      postgres_copy?: Keyword.get(opts, :postgres_copy, false),
      postgres_synchronous_commit: Keyword.get(opts, :postgres_synchronous_commit),
      order: Keyword.get(opts, :order, "default"),
      only: only_variants(Keyword.get(opts, :only)),
      output_json: Keyword.get(opts, :output_json),
      keep_prefixes?: Keyword.get(opts, :keep_prefixes, false),
      explain_dir: Keyword.get(opts, :explain_dir)
    }

    if config.runs < 1, do: Mix.raise("--runs must be at least 1")

    metrics = maybe_start_append_metrics(Keyword.get(opts, :append_metrics, false))

    postgres_repo = start_postgres!(opts)
    duckdb_repo = start_duckdb!(opts, config.concurrency, config.duckdb_threads)
    run_id = System.unique_integer([:positive])

    all_results =
      1..config.runs//1
      |> Enum.flat_map(fn run ->
        benchmark_run(postgres_repo, duckdb_repo, run_id, run, config)
      end)

    print_results(all_results, config)
    maybe_write_json(all_results, config)
    maybe_print_append_metrics(metrics)
    maybe_write_explains(all_results, config)
    cleanup_benchmark_artifacts(all_results, config)
  end

  def handle_quackdb_telemetry([:quackdb, :append, :start], _measurements, metadata, agent) do
    Agent.update(agent, fn state ->
      case Map.get(metadata, :telemetry_span_context) do
        nil -> state
        context -> put_in(state, [:append_context, context], append_table(metadata))
      end
    end)
  end

  def handle_quackdb_telemetry([:quackdb, :append, :stop], measurements, metadata, agent) do
    Agent.update(agent, fn state ->
      context = Map.get(metadata, :telemetry_span_context)
      {table, contexts} = Map.pop(state.append_context, context, append_table(metadata))
      duration = Map.get(measurements, :duration, 0)

      state
      |> Map.put(:append_context, contexts)
      |> update_in([:append, table], fn current ->
        current = current || empty_append_metric()

        current
        |> Map.update!(:calls, &(&1 + 1))
        |> Map.update!(:rows, &(&1 + Map.get(metadata, :rows, 0)))
        |> Map.update!(:batches, &(&1 + Map.get(metadata, :batches, 0)))
        |> Map.update!(:duration, &(&1 + duration))
        |> add_native(metadata, :append_duration)
        |> add_native(metadata, :encode_duration)
        |> add_native(metadata, :transport_duration)
        |> add_native(metadata, :decode_duration)
        |> Map.update!(:request_bytes, &(&1 + Map.get(metadata, :request_bytes, 0)))
        |> Map.update!(:response_bytes, &(&1 + Map.get(metadata, :response_bytes, 0)))
      end)
    end)
  end

  def handle_quackdb_telemetry([:quackdb, :query, :stop], measurements, metadata, agent) do
    Agent.update(agent, fn state ->
      command = Map.get(metadata, :command, :unknown)
      duration = Map.get(measurements, :duration, 0)

      update_in(state, [:query, command], fn current ->
        current = current || %{calls: 0, rows: 0, duration: 0}

        current
        |> Map.update!(:calls, &(&1 + 1))
        |> Map.update!(:rows, &(&1 + Map.get(metadata, :rows, 0)))
        |> Map.update!(:duration, &(&1 + duration))
      end)
    end)
  end

  def handle_quackdb_telemetry(_event, _measurements, _metadata, _agent), do: :ok

  defp run_order(variants, "default"), do: variants
  defp run_order(variants, "reverse"), do: Enum.reverse(variants)

  defp run_order(variants, "random") do
    Enum.shuffle(variants)
  end

  defp run_order(_variants, other), do: Mix.raise("Invalid --order #{inspect(other)}")

  defp only_variants(nil), do: nil

  defp only_variants(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_existing_atom/1)
    |> MapSet.new()
  rescue
    ArgumentError -> Mix.raise("Invalid --only variant list #{inspect(value)}")
  end

  defp include_variant?(%{only: nil}, _label), do: true
  defp include_variant?(%{only: only}, label), do: MapSet.member?(only, label)

  defp start_postgres!(opts) do
    url =
      Keyword.get(opts, :database_url) || System.get_env("EXOGRAPH_DATABASE_URL") ||
        "postgres://dannote@localhost:5432/postgres"

    repo_opts = [
      url: url,
      pool_size: 10,
      log: false,
      timeout: 120_000
    ]

    repo_opts =
      case Keyword.get(opts, :postgres_synchronous_commit) do
        nil -> repo_opts
        value -> Keyword.put(repo_opts, :after_connect, postgres_after_connect(value))
      end

    Application.put_env(:exograph, Exograph.Web.Repo, repo_opts)

    {:ok, _pid} = Exograph.Web.Repo.start_link()
    Exograph.Web.Repo
  end

  defp postgres_after_connect(value)
       when value in ["on", "off", "local", "remote_apply", "remote_write"] do
    fn conn -> Postgrex.query!(conn, "SET synchronous_commit = #{value}", []) end
  end

  defp postgres_after_connect(value),
    do: Mix.raise("Invalid --postgres-synchronous-commit #{inspect(value)}")

  defp start_duckdb!(opts, pool_size, duckdb_threads) do
    Application.ensure_all_started(:quackdb)

    uri =
      Keyword.get(opts, :quackdb_uri) || System.get_env("QUACKDB_URI") ||
        System.get_env("QUACKDB_TEST_URI") || Mix.raise("Missing --quackdb-uri")

    token =
      Keyword.get(opts, :quackdb_token) || System.get_env("QUACKDB_TOKEN") ||
        System.get_env("QUACKDB_TEST_TOKEN") || ""

    start_duckdb_repo!(Exograph.DuckDBRepo, uri, token, pool_size, duckdb_threads)
  end

  defp start_duckdb_repo!(repo, uri, token, pool_size, duckdb_threads) do
    Application.put_env(:exograph, repo,
      uri: uri,
      token: token,
      pool_size: pool_size,
      telemetry_prefix: [:quackdb],
      log: false,
      timeout: 120_000
    )

    {:ok, _pid} = repo.start_link()
    Exograph.DuckDB.configure_threads!(repo, duckdb_threads)
    repo
  end

  defp benchmark_run(postgres_repo, duckdb_repo, run_id, run, config) do
    results =
      run_order(
        [
          {:postgres_plain, :postgres, false, postgres_repo, "bench_pg_plain_#{run_id}_r#{run}"},
          {:postgres_bm25, :postgres, true, postgres_repo, "bench_pg_bm25_#{run_id}_r#{run}"},
          {:duckdb_plain, :duckdb, false, duckdb_repo, "bench_duck_plain_#{run_id}_r#{run}"},
          {:duckdb_bm25, :duckdb, true, duckdb_repo, "bench_duck_bm25_#{run_id}_r#{run}"}
        ],
        config.order
      )
      |> Enum.filter(fn {label, _backend, _bm25?, _repo, _prefix} ->
        include_variant?(config, label)
      end)
      |> Enum.map(fn {label, backend, bm25?, repo, prefix} ->
        label
        |> benchmark_backend(backend, bm25?, repo, prefix, config)
        |> Map.put(:run, run)
      end)

    sharded_results =
      if config.duckdb_shards > 1 do
        [
          {:duckdb_sharded_plain, false},
          {:duckdb_sharded_bm25, true}
        ]
        |> Enum.filter(fn {label, _bm25?} -> include_variant?(config, label) end)
        |> Enum.map(fn {label, bm25?} ->
          label
          |> benchmark_sharded_duckdb(bm25?, run_id, run, config)
          |> Map.put(:run, run)
        end)
      else
        []
      end

    results ++ sharded_results
  end

  defp benchmark_backend(label, backend, bm25?, repo, prefix, config) do
    drop_prefix(repo, prefix)

    index_opts = [
      backend: backend,
      repo: repo,
      prefix: prefix,
      mode: config.mode,
      limit: config.limit,
      concurrency: config.concurrency,
      index_concurrency: config.index_concurrency,
      min_mass: config.min_mass,
      resume: false,
      bm25?: bm25?,
      timeout: config.timeout,
      cache_dir: config.cache_dir,
      duckdb_threads: config.duckdb_threads,
      postgres_maintenance_work_mem: config.postgres_maintenance_work_mem,
      postgres_max_parallel_maintenance_workers: config.postgres_max_parallel_maintenance_workers,
      postgres_unlogged?: config.postgres_unlogged?,
      postgres_defer_indexes?: config.postgres_defer_indexes?,
      postgres_copy?: config.postgres_copy?
    ]

    Mix.shell().info("\nIndexing #{label} prefix=#{prefix}...")

    {index_ms, corpus_result} = timed(fn -> Exograph.Hex.Corpus.index(index_opts) end)

    {:ok, index} =
      Exograph.index([],
        backend: backend,
        repo: repo,
        prefix: prefix,
        migrate?: false,
        bm25?: bm25?,
        duckdb_threads: config.duckdb_threads
      )

    %{
      label: label,
      backend: backend,
      bm25?: bm25?,
      prefix: prefix,
      index_ms: index_ms,
      corpus: corpus_result,
      fragments: count_rows(repo, prefix, "fragments"),
      files: count_rows(repo, prefix, "files"),
      queries: benchmark_queries(backend, bm25?, repo, prefix, index, config),
      cleanup: {:repo_prefix, repo, prefix}
    }
  rescue
    error ->
      %{
        label: label,
        backend: backend,
        bm25?: bm25?,
        prefix: prefix,
        error: Exception.message(error),
        index_ms: 0.0,
        corpus: %{ok: 0, skipped: 0, error: 1},
        fragments: 0,
        files: 0,
        queries: [],
        cleanup: {:repo_prefix, repo, prefix}
      }
  end

  defp benchmark_sharded_duckdb(label, bm25?, run_id, run, config) do
    prefix = "bench_duck_shard_#{run_id}_r#{run}_#{if(bm25?, do: "bm25", else: "plain")}"

    Mix.shell().info("\nIndexing #{label} shards=#{config.duckdb_shards} prefix=#{prefix}...")

    index_opts = [
      backend: :duckdb,
      repo: Exograph.DuckDBRepo,
      prefix: prefix,
      mode: config.mode,
      limit: config.limit,
      concurrency: 1,
      index_concurrency: config.index_concurrency,
      min_mass: config.min_mass,
      resume: false,
      bm25?: bm25?,
      timeout: config.timeout,
      cache_dir: config.cache_dir,
      duckdb_threads: config.duckdb_threads,
      recovery_mode: config.duckdb_recovery_mode,
      shards: config.duckdb_shards,
      shard_port_base: sharded_port_base(run, bm25?)
    ]

    {index_ms, corpus_result} = timed(fn -> Exograph.Hex.Corpus.index(index_opts) end)
    sharded_index = Map.fetch!(corpus_result, :index)
    shards = sharded_index.shards

    %{
      label: label,
      backend: :duckdb_sharded,
      bm25?: bm25?,
      prefix: "#{config.duckdb_shards} shards",
      index_ms: index_ms,
      corpus: corpus_result,
      fragments: Enum.sum(Enum.map(shards, &shard_count_rows(&1, "fragments"))),
      files: Enum.sum(Enum.map(shards, &shard_count_rows(&1, "files"))),
      queries: benchmark_sharded_queries(bm25?, sharded_index, config),
      cleanup: {:shards, shards}
    }
  rescue
    error ->
      %{
        label: label,
        backend: :duckdb_sharded,
        bm25?: bm25?,
        prefix: "#{config.duckdb_shards} shards",
        error: Exception.message(error),
        index_ms: 0.0,
        corpus: %{ok: 0, skipped: 0, error: 1},
        fragments: 0,
        files: 0,
        queries: []
      }
  end

  defp sharded_port_base(run, bm25?) do
    9_600 + run * 100 + if(bm25?, do: 50, else: 0)
  end

  defp benchmark_queries(backend, bm25?, repo, prefix, index, config) do
    raw_results =
      Enum.map(queries(bm25?), fn {name, table, where, params} ->
        try do
          Enum.each(1..config.warmup//1, fn _ ->
            run_count_query(backend, repo, prefix, table, where, params)
          end)

          samples =
            Enum.map(1..config.iterations//1, fn _ ->
              timed(fn -> run_count_query(backend, repo, prefix, table, where, params) end)
            end)

          counts = Enum.map(samples, &elem(&1, 1))
          times = Enum.map(samples, &elem(&1, 0))
          {min_ms, max_ms} = min_max(times)

          {name,
           %{
             median_ms: median(times),
             min_ms: min_ms,
             max_ms: max_ms,
             result_count: median(counts)
           }}
        rescue
          error -> {name, %{error: Exception.message(error)}}
        end
      end)

    raw_results ++ benchmark_api_queries(index, config)
  end

  defp benchmark_api_queries(index, config) do
    Enum.map(api_queries(), fn {name, fun} ->
      try do
        Enum.each(1..config.warmup//1, fn _ -> run_api_query(index, fun) end)

        samples =
          Enum.map(1..config.iterations//1, fn _ ->
            timed(fn -> run_api_query(index, fun) end)
          end)

        counts = Enum.map(samples, &elem(&1, 1))
        times = Enum.map(samples, &elem(&1, 0))
        {min_ms, max_ms} = min_max(times)

        {name,
         %{
           median_ms: median(times),
           min_ms: min_ms,
           max_ms: max_ms,
           result_count: median(counts)
         }}
      rescue
        error -> {name, %{error: Exception.message(error)}}
      end
    end)
  end

  defp benchmark_sharded_queries(bm25?, index, config) do
    raw_results =
      Enum.map(queries(bm25?), fn {name, table, where, params} ->
        try do
          Enum.each(1..config.warmup//1, fn _ ->
            run_sharded_count_query(index, table, where, params)
          end)

          samples =
            Enum.map(1..config.iterations//1, fn _ ->
              timed(fn -> run_sharded_count_query(index, table, where, params) end)
            end)

          counts = Enum.map(samples, &elem(&1, 1))
          times = Enum.map(samples, &elem(&1, 0))
          {min_ms, max_ms} = min_max(times)

          {name,
           %{
             median_ms: median(times),
             min_ms: min_ms,
             max_ms: max_ms,
             result_count: median(counts)
           }}
        rescue
          error -> {name, %{error: Exception.message(error)}}
        end
      end)

    raw_results ++ benchmark_api_queries(index, config)
  end

  defp run_sharded_count_query(%Exograph.ShardedIndex{shards: shards}, table, where, params) do
    shards
    |> Task.async_stream(
      fn shard ->
        Exograph.DuckDBShards.with_repo(shard, fn ->
          index = Map.fetch!(shard, :index)

          run_count_query(
            :duckdb,
            index.inverted.repo,
            index.inverted.prefix,
            table,
            where,
            params
          )
        end)
      end,
      max_concurrency: length(shards),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(0, fn {:ok, count}, acc -> acc + count end)
  end

  defp shard_count_rows(shard, table) do
    Exograph.DuckDBShards.with_repo(shard, fn -> count_rows(shard.repo, shard.prefix, table) end)
  end

  defp run_api_query(index, fun) do
    {:ok, results} = fun.(index)
    length(results)
  end

  defp count_rows(repo, prefix, table) do
    %{rows: [[count]]} =
      repo.query!(
        "SELECT COUNT(*) FROM #{Exograph.Storage.Ecto.SQL.table(prefix, table)}",
        []
      )

    count
  end

  defp run_count_query(:postgres, repo, prefix, table, where, params) do
    sql =
      "SELECT COUNT(*) FROM #{Exograph.Storage.Ecto.SQL.table(prefix, table)} WHERE #{pg_placeholders(where)}"

    %{rows: [[count]]} = repo.query!(sql, params)
    count
  end

  defp run_count_query(:duckdb, repo, prefix, table, where, params) do
    where = duckdb_where(prefix, table, where)
    sql = "SELECT COUNT(*) FROM #{Exograph.Storage.Ecto.SQL.table(prefix, table)} WHERE #{where}"
    %{rows: [[count]]} = repo.query!(sql, params)
    count
  end

  defp duckdb_where(prefix, table, {:bm25, column, _query}) do
    schema = QuackDB.FTS.schema_name("main.#{prefix}_#{table}")
    ~s|"#{schema}".match_bm25("id", ?, fields := '#{column}') > 0|
  end

  defp duckdb_where(_prefix, _table, where), do: where

  defp pg_placeholders({:bm25, column, _query}) do
    case column do
      "source" -> "source::pdb.source_code ||| $1"
      "comments_text" -> "comments_text::pdb.unicode_words ||| $1"
      _ -> "#{column}::pdb.ngram(2, 96, 'prefix_only=true') ||| $1"
    end
  end

  defp pg_placeholders(sql) do
    sql
    |> String.split("?")
    |> Enum.with_index()
    |> Enum.map(fn
      {part, 0} -> part
      {part, index} -> ["$", Integer.to_string(index), part]
    end)
    |> IO.iodata_to_binary()
  end

  defp timed(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    stop = System.monotonic_time(:microsecond)
    {(stop - start) / 1000, result}
  end

  defp min_max([first | rest]) do
    Enum.reduce(rest, {first, first}, fn value, {min, max} ->
      {Kernel.min(min, value), Kernel.max(max, value)}
    end)
  end

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    case {rem(count, 2), div(count, 2)} do
      {1, mid} -> Enum.at(sorted, mid)
      {0, mid} -> (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  defp maybe_write_explains(_results, %{explain_dir: nil}), do: :ok

  defp maybe_write_explains(results, %{explain_dir: dir}) do
    File.mkdir_p!(dir)

    results
    |> Enum.filter(&(&1.backend == :postgres and not Map.has_key?(&1, :error)))
    |> Enum.each(&write_postgres_explains(&1, dir))

    Mix.shell().info("\nWrote Postgres EXPLAIN plans to #{dir}")
  end

  defp write_postgres_explains(
         %{cleanup: {:repo_prefix, repo, prefix}, label: label, run: run},
         dir
       ) do
    explain_queries(prefix)
    |> Enum.each(fn {name, sql, params} ->
      path = Path.join(dir, "#{label}-run#{run}-#{name}.txt")
      explain_sql = "EXPLAIN (ANALYZE, BUFFERS) " <> sql

      text =
        case Ecto.Adapters.SQL.query(repo, explain_sql, params, timeout: :infinity) do
          {:ok, %{rows: rows}} ->
            rows
            |> Enum.map(fn [line] -> line end)
            |> Enum.join("\n")

          {:error, error} ->
            "EXPLAIN failed: #{Exception.message(error)}"
        end

      File.write!(path, text <> "\n")
    end)
  end

  defp write_postgres_explains(_result, _dir), do: :ok

  defp explain_queries(prefix) do
    raw =
      queries(false)
      |> Enum.map(fn {name, table, where, params} ->
        sql =
          "SELECT COUNT(*) FROM #{Exograph.Storage.Ecto.SQL.table(prefix, table)} WHERE #{pg_placeholders(where)}"

        {name, sql, params}
      end)

    raw ++
      [
        {:api_text_defmodule, explain_file_search_sql(prefix, :source), ["%defmodule%", 50]},
        {:api_comments_todo, explain_file_search_sql(prefix, :comments_text), ["%TODO%", 50]}
      ]
  end

  defp explain_file_search_sql(prefix, field) when field in [:source, :comments_text] do
    files = Exograph.Storage.Ecto.SQL.table(prefix, "files")
    fragments = Exograph.Storage.Ecto.SQL.table(prefix, "fragments")
    field = Atom.to_string(field)

    """
    SELECT fragment.id
    FROM #{files} AS file
    INNER JOIN LATERAL (
      SELECT fragment.id
      FROM #{fragments} AS fragment
      WHERE fragment.file_id = file.id
      ORDER BY fragment.line
      LIMIT 1
    ) AS fragment ON TRUE
    WHERE file.#{field} ILIKE $1
    ORDER BY file.path
    LIMIT $2
    """
  end

  defp maybe_write_json(_results, %{output_json: nil}), do: :ok

  defp maybe_write_json(results, %{output_json: path} = config) do
    document = benchmark_json_document(results, config)
    File.write!(path, Jason.encode_to_iodata!(document, pretty: true))
    Mix.shell().info("\nWrote JSON benchmark results to #{path}")
  end

  defp benchmark_json_document(results, config) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      git: %{sha: git_sha(), branch: git_branch()},
      system: system_info(),
      versions: dependency_versions(),
      config: json_config(config),
      results: Enum.map(results, &json_result/1)
    }
    |> normalize_json_data()
  end

  defp json_config(config) do
    config
    |> Map.update!(:mode, &to_string/1)
    |> Map.update!(:duckdb_recovery_mode, &json_recovery_mode/1)
    |> Map.update!(:only, fn
      nil -> nil
      only -> only |> MapSet.to_list() |> Enum.map(&to_string/1) |> Enum.sort()
    end)
  end

  defp json_recovery_mode(nil), do: nil
  defp json_recovery_mode(value) when is_atom(value), do: to_string(value)
  defp json_recovery_mode(value), do: value

  defp json_result(result) do
    result
    |> Map.drop([:cleanup])
    |> Map.update!(:label, &to_string/1)
    |> Map.update!(:backend, &to_string/1)
    |> Map.update!(:corpus, &Map.drop(&1, [:index, :manifest]))
    |> Map.update!(:queries, fn queries ->
      Map.new(queries, fn {name, stats} -> {to_string(name), stats} end)
    end)
  end

  defp normalize_json_data(%{} = map) do
    Map.new(map, fn {key, value} -> {json_key(key), normalize_json_data(value)} end)
  end

  defp normalize_json_data(list) when is_list(list), do: Enum.map(list, &normalize_json_data/1)
  defp normalize_json_data(value), do: value

  defp json_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.trim_trailing("?")
  end

  defp json_key(key), do: key

  defp git_sha do
    git_output(["rev-parse", "HEAD"])
  end

  defp git_branch do
    git_output(["rev-parse", "--abbrev-ref", "HEAD"])
  end

  defp git_output(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _other -> nil
    end
  rescue
    _ -> nil
  end

  defp system_info do
    %{
      otp_release: System.otp_release(),
      elixir: System.version(),
      schedulers_online: System.schedulers_online(),
      os: :os.type() |> Tuple.to_list() |> Enum.map(&to_string/1),
      arch: :erlang.system_info(:system_architecture) |> to_string()
    }
  end

  defp dependency_versions do
    [:ecto, :ecto_sql, :postgrex, :quackdb]
    |> Map.new(fn app -> {app, app_version(app)} end)
  end

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      version -> to_string(version)
    end
  end

  defp print_results(results, config) do
    Mix.shell().info("\nBackend benchmark")

    duckdb_threads = config.duckdb_threads || "default"
    index_concurrency = config.index_concurrency || "corpus-default"

    postgres_settings =
      postgres_settings_label(
        config.postgres_maintenance_work_mem,
        config.postgres_max_parallel_maintenance_workers,
        config.postgres_unlogged?,
        config.postgres_defer_indexes?,
        config.postgres_copy?,
        config.postgres_synchronous_commit
      )

    Mix.shell().info(
      "  workload: #{config.mode} limit=#{config.limit} runs=#{config.runs} concurrency=#{config.concurrency} index_concurrency=#{index_concurrency} duckdb_threads=#{duckdb_threads} duckdb_shards=#{config.duckdb_shards} postgres_settings=#{postgres_settings} order=#{config.order}"
    )

    Mix.shell().info("  queries: warmup=#{config.warmup} iterations=#{config.iterations}\n")

    Enum.each(results, fn result ->
      Mix.shell().info([
        String.upcase(display_label(result)),
        " index_ms=",
        format_ms(result.index_ms),
        " ok=",
        to_string(result.corpus.ok),
        " skipped=",
        to_string(result.corpus.skipped),
        " errors=",
        to_string(result.corpus.error),
        " files=",
        to_string(result.files),
        " fragments=",
        to_string(result.fragments),
        if(result[:error], do: " error=#{result.error}", else: "")
      ])
    end)

    maybe_print_run_summary(results, config)

    Mix.shell().info("\nQuery medians")

    all_query_names(results)
    |> Enum.each(fn name ->
      line =
        results
        |> Enum.map(fn result ->
          case Keyword.fetch(result.queries, name) do
            {:ok, %{error: error}} ->
              [display_label(result), "=error(", short_error(error), ")"]

            {:ok, stats} ->
              [
                display_label(result),
                "=",
                format_ms(stats.median_ms),
                "ms(n=",
                to_string(stats.result_count),
                ")"
              ]

            :error ->
              [display_label(result), "=n/a"]
          end
        end)
        |> Enum.intersperse("  ")
        |> IO.iodata_to_binary()

      Mix.shell().info("  #{name}: #{line}")
    end)
  end

  defp display_label(%{run: run, label: label}), do: "#{label}[#{run}]"
  defp display_label(%{label: label}), do: to_string(label)

  defp maybe_print_run_summary(_results, %{runs: 1}), do: :ok

  defp maybe_print_run_summary(results, %{runs: runs}) do
    Mix.shell().info("\nIndex run summary (#{runs} runs)")

    results
    |> Enum.group_by(& &1.label)
    |> Enum.sort_by(fn {label, _results} -> to_string(label) end)
    |> Enum.each(fn {label, grouped} ->
      times = Enum.map(grouped, & &1.index_ms)
      {min_ms, max_ms} = min_max(times)

      Mix.shell().info(
        "  #{label}: median=#{format_ms(median(times))}ms min=#{format_ms(min_ms)}ms max=#{format_ms(max_ms)}ms"
      )
    end)
  end

  defp postgres_settings_label(
         maintenance_work_mem,
         parallel_workers,
         unlogged?,
         defer_indexes?,
         copy?,
         synchronous_commit
       ) do
    settings =
      [
        if(maintenance_work_mem, do: "maintenance_work_mem=#{maintenance_work_mem}"),
        if(parallel_workers, do: "max_parallel_maintenance_workers=#{parallel_workers}"),
        if(unlogged?, do: "unlogged=true"),
        if(defer_indexes?, do: "defer_indexes=true"),
        if(copy?, do: "copy=true"),
        if(synchronous_commit, do: "synchronous_commit=#{synchronous_commit}")
      ]
      |> Enum.reject(&is_nil/1)

    if settings == [], do: "default", else: Enum.join(settings, ",")
  end

  defp all_query_names(results) do
    results
    |> Enum.flat_map(&Keyword.keys(&1.queries))
    |> Enum.uniq()
  end

  defp api_queries do
    [
      {:api_text_defmodule, fn index -> Exograph.search_text(index, "defmodule", limit: 50) end},
      {:api_comments_todo, fn index -> Exograph.search_comments(index, "TODO", limit: 50) end}
    ]
  end

  defp queries(false) do
    [
      {:definitions_decode, "definitions", "qualified_name ILIKE ?", ["%decode%"]},
      {:references_enum, "references", "qualified_name ILIKE ?", ["%Enum%"]},
      {:call_edges_decode, "call_edges", "callee_qualified_name ILIKE ?", ["%decode%"]},
      {:fragments_def, "fragments", "kind = ?", ["def"]},
      {:files_defmodule, "files", "source ILIKE ?", ["%defmodule%"]}
    ]
  end

  defp queries(true), do: []

  defp short_error(error) do
    error
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 80)
  end

  defp format_ms(value), do: :erlang.float_to_binary(value / 1.0, decimals: 1)

  defp recovery_mode(nil), do: nil
  defp recovery_mode("no_wal_writes"), do: :no_wal_writes
  defp recovery_mode(value), do: Mix.raise("Unknown DuckDB recovery mode #{inspect(value)}")

  defp maybe_start_append_metrics(false), do: nil

  defp maybe_start_append_metrics(true) do
    id = "exograph-bench-quackdb-#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> %{append: %{}, append_context: %{}, query: %{}} end)

    :telemetry.attach_many(
      id,
      [
        [:quackdb, :append, :start],
        [:quackdb, :append, :stop],
        [:quackdb, :query, :stop]
      ],
      &__MODULE__.handle_quackdb_telemetry/4,
      agent
    )

    {id, agent}
  end

  defp maybe_print_append_metrics(nil), do: :ok

  defp maybe_print_append_metrics({id, agent}) do
    :telemetry.detach(id)
    %{append: append, query: query} = Agent.get(agent, & &1)
    Agent.stop(agent)

    Mix.shell().info("\nQuackDB append metrics")

    append
    |> Enum.sort_by(fn {_table, metrics} -> -metrics.rows end)
    |> Enum.each(fn {table, metrics} ->
      seconds = native_seconds(metrics.append_duration)
      rows_per_second = if seconds > 0, do: metrics.rows / seconds, else: 0.0

      Mix.shell().info(
        "  #{table}: rows=#{metrics.rows} batches=#{metrics.batches} calls=#{metrics.calls} rows_per_sec=#{format_ms(rows_per_second)} encode_ms=#{format_native_ms(metrics.encode_duration)} transport_ms=#{format_native_ms(metrics.transport_duration)} decode_ms=#{format_native_ms(metrics.decode_duration)} request_mb=#{format_ms(metrics.request_bytes / 1_000_000)}"
      )
    end)

    Mix.shell().info("\nQuackDB query metrics")

    query
    |> Enum.sort_by(fn {_command, metrics} -> -metrics.duration end)
    |> Enum.each(fn {command, metrics} ->
      Mix.shell().info(
        "  #{command}: calls=#{metrics.calls} rows=#{metrics.rows} total_ms=#{format_native_ms(metrics.duration)}"
      )
    end)
  end

  defp empty_append_metric do
    %{
      calls: 0,
      rows: 0,
      batches: 0,
      duration: 0,
      append_duration: 0,
      encode_duration: 0,
      transport_duration: 0,
      decode_duration: 0,
      request_bytes: 0,
      response_bytes: 0
    }
  end

  defp append_table(metadata) do
    schema = Map.get(metadata, :schema, "")
    table = Map.get(metadata, :table, "unknown")

    table = normalize_append_table(table)

    if schema in [nil, ""] do
      table
    else
      schema <> "." <> table
    end
  end

  defp normalize_append_table("quackdb_append_" <> _suffix), do: "quackdb_append_*"
  defp normalize_append_table(table), do: table

  defp add_native(metrics, metadata, key),
    do: Map.update!(metrics, key, &(&1 + Map.get(metadata, key, 0)))

  defp format_native_ms(value), do: value |> native_ms() |> format_ms()

  defp native_ms(value), do: System.convert_time_unit(value, :native, :microsecond) / 1000

  defp native_seconds(value),
    do: System.convert_time_unit(value, :native, :microsecond) / 1_000_000

  defp cleanup_benchmark_artifacts(_results, %{keep_prefixes?: true}) do
    Mix.shell().info("\nKeeping benchmark prefixes (--keep-prefixes)")
    :ok
  end

  defp cleanup_benchmark_artifacts(results, _config) do
    Mix.shell().info("\nCleaning benchmark prefixes")

    Enum.each(results, fn result ->
      case Map.get(result, :cleanup) do
        {:repo_prefix, repo, prefix} ->
          drop_prefix(repo, prefix)

        {:shards, shards} ->
          Enum.each(shards, fn shard ->
            Exograph.DuckDBShards.with_repo(shard, fn -> drop_prefix(shard.repo, shard.prefix) end)

            stop_shard(shard)
          end)

        _other ->
          :ok
      end
    end)
  end

  defp stop_shard(shard) do
    [Map.get(shard, :dynamic_repo), Map.get(shard, :server)]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)
  end

  defp drop_prefix(repo, prefix) do
    Enum.each(@tables, fn table ->
      query(repo, "DROP TABLE IF EXISTS #{Exograph.Storage.Ecto.SQL.table(prefix, table)}")
    end)

    Enum.each(@tables, fn table ->
      query(repo, ~s|DROP SEQUENCE IF EXISTS "#{prefix}_#{table}_id_seq"|)

      query(
        repo,
        ~s|DROP SCHEMA IF EXISTS "#{QuackDB.FTS.schema_name("main.#{prefix}_#{table}")}" CASCADE|
      )
    end)
  end

  defp query(repo, sql) do
    repo.query(sql, [])
    :ok
  rescue
    _ -> :ok
  end
end
