defmodule Mix.Tasks.Exograph.Bench.Backends do
  use Mix.Task

  @shortdoc "Compare Postgres and DuckDB indexing/query speed"

  @moduledoc """
  Benchmarks Exograph indexing and query speed across Postgres and DuckDB using
  the same Hex.pm package workload.

      mix exograph.bench.backends --mode top --limit 20 --iterations 10
      mix exograph.bench.backends --mode top --limit 20 --concurrency 4 --duckdb-threads 1
      mix exograph.bench.backends --mode top --limit 20 --duckdb-shards 4 --duckdb-threads 1

  Required services:

    * Postgres: `EXOGRAPH_DATABASE_URL` or `--database-url`
    * DuckDB: `QUACKDB_URI` / `QUACKDB_TEST_URI` or `--quackdb-uri`

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
          min_mass: :integer,
          cache_tarballs: :string,
          database_url: :string,
          quackdb_uri: :string,
          quackdb_token: :string,
          duckdb_threads: :integer,
          duckdb_shards: :integer,
          timeout: :integer
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
      min_mass: Keyword.get(opts, :min_mass, 8),
      timeout: Keyword.get(opts, :timeout, 300) * 1000,
      cache_dir: Keyword.get(opts, :cache_tarballs),
      duckdb_threads: Keyword.get(opts, :duckdb_threads),
      duckdb_shards: Keyword.get(opts, :duckdb_shards, 0)
    }

    postgres_repo = start_postgres!(opts)
    duckdb_repo = start_duckdb!(opts, config.concurrency, config.duckdb_threads)
    run_id = System.unique_integer([:positive])

    results =
      [
        {:postgres_plain, :postgres, false, postgres_repo, "bench_pg_plain_#{run_id}"},
        {:postgres_bm25, :postgres, true, postgres_repo, "bench_pg_bm25_#{run_id}"},
        {:duckdb_plain, :duckdb, false, duckdb_repo, "bench_duck_plain_#{run_id}"},
        {:duckdb_bm25, :duckdb, true, duckdb_repo, "bench_duck_bm25_#{run_id}"}
      ]
      |> Enum.map(fn {label, backend, bm25?, repo, prefix} ->
        benchmark_backend(label, backend, bm25?, repo, prefix, config)
      end)

    sharded_results =
      if config.duckdb_shards > 1 do
        shard_repos = start_duckdb_shards!(config.duckdb_shards, config.duckdb_threads)

        [
          benchmark_sharded_duckdb(:duckdb_sharded_plain, false, shard_repos, run_id, config),
          benchmark_sharded_duckdb(:duckdb_sharded_bm25, true, shard_repos, run_id, config)
        ]
      else
        []
      end

    print_results(results ++ sharded_results, config)
  end

  defp start_postgres!(opts) do
    url =
      Keyword.get(opts, :database_url) || System.get_env("EXOGRAPH_DATABASE_URL") ||
        "postgres://dannote@localhost:5432/postgres"

    Application.put_env(:exograph, Exograph.Web.Repo,
      url: url,
      pool_size: 10,
      log: false,
      timeout: 120_000
    )

    {:ok, _pid} = Exograph.Web.Repo.start_link()
    Exograph.Web.Repo
  end

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

  defp start_duckdb_shards!(count, duckdb_threads) when count in 2..8 do
    Application.ensure_all_started(:quackdb)

    shard_repo_modules()
    |> Enum.take(count)
    |> Enum.with_index()
    |> Enum.map(fn {repo, index} ->
      database =
        Path.join(
          System.tmp_dir!(),
          "exograph-bench-shard-#{index}-#{System.unique_integer([:positive])}.duckdb"
        )

      token = "bench-shard-#{index}"
      endpoint = "quack:localhost:#{9600 + index}"

      {:ok, server} =
        QuackDB.Server.start_link(
          duckdb: :managed,
          database: database,
          endpoint: endpoint,
          token: token
        )

      start_duckdb_repo!(repo, QuackDB.Server.uri(server), token, 1, duckdb_threads)
    end)
  end

  defp start_duckdb_shards!(count, _duckdb_threads) do
    Mix.raise("--duckdb-shards must be between 2 and 8, got #{count}")
  end

  defp start_duckdb_repo!(repo, uri, token, pool_size, duckdb_threads) do
    Application.put_env(:exograph, repo,
      uri: uri,
      token: token,
      pool_size: pool_size,
      log: false,
      timeout: 120_000
    )

    {:ok, _pid} = repo.start_link()
    Exograph.DuckDB.configure_threads!(repo, duckdb_threads)
    repo
  end

  defp shard_repo_modules do
    [
      Exograph.DuckDBShardRepo0,
      Exograph.DuckDBShardRepo1,
      Exograph.DuckDBShardRepo2,
      Exograph.DuckDBShardRepo3,
      Exograph.DuckDBShardRepo4,
      Exograph.DuckDBShardRepo5,
      Exograph.DuckDBShardRepo6,
      Exograph.DuckDBShardRepo7
    ]
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
      duckdb_threads: config.duckdb_threads
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
      queries: benchmark_queries(backend, bm25?, repo, prefix, index, config)
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
        queries: []
      }
  end

  defp benchmark_sharded_duckdb(label, bm25?, repos, run_id, config) do
    entries = list_benchmark_entries(config)
    shard_count = length(repos)

    entries_by_shard = entries_by_shard(entries, shard_count)

    shards =
      repos
      |> Enum.with_index()
      |> Enum.map(fn {repo, index} ->
        %{
          repo: repo,
          prefix: "bench_duck_shard_#{run_id}_#{if(bm25?, do: "bm25", else: "plain")}_#{index}",
          entries: Map.fetch!(entries_by_shard, index)
        }
      end)

    Enum.each(shards, fn shard ->
      drop_prefix(shard.repo, shard.prefix)
      Exograph.DuckDB.migrate!(repo: shard.repo, prefix: shard.prefix)
    end)

    Mix.shell().info("\nIndexing #{label} shards=#{shard_count}...")

    {index_ms, corpus_results} =
      timed(fn ->
        shards
        |> Task.async_stream(
          fn shard -> index_shard(shard, bm25?, config) end,
          max_concurrency: shard_count,
          timeout: :infinity,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    shard_indexes =
      Enum.map(shards, fn shard ->
        {:ok, index} =
          Exograph.index([],
            backend: :duckdb,
            repo: shard.repo,
            prefix: shard.prefix,
            migrate?: false,
            bm25?: bm25?,
            duckdb_threads: config.duckdb_threads
          )

        Map.put(shard, :index, index)
      end)

    sharded_index = Exograph.ShardedIndex.new(Enum.map(shard_indexes, & &1.index))

    %{
      label: label,
      backend: :duckdb_sharded,
      bm25?: bm25?,
      prefix: "#{shard_count} shards",
      index_ms: index_ms,
      corpus: combine_corpus_results(corpus_results),
      fragments: Enum.sum(Enum.map(shards, &count_rows(&1.repo, &1.prefix, "fragments"))),
      files: Enum.sum(Enum.map(shards, &count_rows(&1.repo, &1.prefix, "files"))),
      queries: benchmark_sharded_queries(bm25?, sharded_index, config)
    }
  rescue
    error ->
      %{
        label: label,
        backend: :duckdb_sharded,
        bm25?: bm25?,
        prefix: "#{length(repos)} shards",
        error: Exception.message(error),
        index_ms: 0.0,
        corpus: %{ok: 0, skipped: 0, error: 1},
        fragments: 0,
        files: 0,
        queries: []
      }
  end

  defp list_benchmark_entries(config) do
    opts = [mode: config.mode, limit: config.limit, cache_dir: config.cache_dir]

    case config.mode do
      :latest -> Exograph.Hex.Registry.latest(opts)
      :top -> Exograph.Hex.Registry.top(opts)
      :all -> Exograph.Hex.Registry.all_versions(opts)
    end
  end

  defp entries_by_shard(entries, shard_count) do
    empty = Map.new(0..(shard_count - 1), &{&1, []})

    entries
    |> Enum.with_index()
    |> Enum.reduce(empty, fn {entry, index}, acc ->
      Map.update!(acc, rem(index, shard_count), &[entry | &1])
    end)
    |> Map.new(fn {index, entries} -> {index, Enum.reverse(entries)} end)
  end

  defp index_shard(shard, bm25?, config) do
    Exograph.Hex.Corpus.index(
      backend: :duckdb,
      repo: shard.repo,
      prefix: shard.prefix,
      entries: shard.entries,
      mode: config.mode,
      concurrency: 1,
      index_concurrency: config.index_concurrency,
      min_mass: config.min_mass,
      resume: false,
      migrate?: false,
      bm25?: bm25?,
      timeout: config.timeout,
      cache_dir: config.cache_dir,
      duckdb_threads: config.duckdb_threads
    )
  end

  defp combine_corpus_results(results) do
    Enum.reduce(results, %{ok: 0, skipped: 0, error: 0}, fn result, acc ->
      %{
        ok: acc.ok + result.ok,
        skipped: acc.skipped + result.skipped,
        error: acc.error + result.error
      }
    end)
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
        run_count_query(:duckdb, shard.inverted.repo, shard.inverted.prefix, table, where, params)
      end,
      max_concurrency: length(shards),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(0, fn {:ok, count}, acc -> acc + count end)
  end

  defp run_api_query(index, fun) do
    {:ok, results} = fun.(index)
    length(results)
  end

  defp count_rows(repo, prefix, table) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT COUNT(*) FROM #{Exograph.Postgres.table(prefix, table)}",
        []
      )

    count
  end

  defp run_count_query(:postgres, repo, prefix, table, where, params) do
    sql =
      "SELECT COUNT(*) FROM #{Exograph.Postgres.table(prefix, table)} WHERE #{pg_placeholders(where)}"

    %{rows: [[count]]} = Ecto.Adapters.SQL.query!(repo, sql, params)
    count
  end

  defp run_count_query(:duckdb, repo, prefix, table, where, params) do
    where = duckdb_where(prefix, table, where)
    sql = "SELECT COUNT(*) FROM #{Exograph.Postgres.table(prefix, table)} WHERE #{where}"
    %{rows: [[count]]} = Ecto.Adapters.SQL.query!(repo, sql, params)
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

  defp print_results(results, config) do
    Mix.shell().info("\nBackend benchmark")

    duckdb_threads = config.duckdb_threads || "default"
    index_concurrency = config.index_concurrency || "corpus-default"

    Mix.shell().info(
      "  workload: #{config.mode} limit=#{config.limit} concurrency=#{config.concurrency} index_concurrency=#{index_concurrency} duckdb_threads=#{duckdb_threads} duckdb_shards=#{config.duckdb_shards}"
    )

    Mix.shell().info("  queries: warmup=#{config.warmup} iterations=#{config.iterations}\n")

    Enum.each(results, fn result ->
      Mix.shell().info([
        String.upcase(to_string(result.label)),
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

    Mix.shell().info("\nQuery medians")

    all_query_names(results)
    |> Enum.each(fn name ->
      line =
        results
        |> Enum.map(fn result ->
          case Keyword.fetch(result.queries, name) do
            {:ok, %{error: error}} ->
              [to_string(result.label), "=error(", short_error(error), ")"]

            {:ok, stats} ->
              [
                to_string(result.label),
                "=",
                format_ms(stats.median_ms),
                "ms(n=",
                to_string(stats.result_count),
                ")"
              ]

            :error ->
              [to_string(result.label), "=n/a"]
          end
        end)
        |> Enum.intersperse("  ")
        |> IO.iodata_to_binary()

      Mix.shell().info("  #{name}: #{line}")
    end)
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

  defp drop_prefix(repo, prefix) do
    Enum.each(@tables, fn table ->
      query(repo, "DROP TABLE IF EXISTS #{Exograph.Postgres.table(prefix, table)}")
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
    Ecto.Adapters.SQL.query(repo, sql, [])
    :ok
  rescue
    _ -> :ok
  end
end
