defmodule Exograph.Hex.Corpus do
  @moduledoc false

  alias Exograph.Hex.{Downloader, Progress, Registry}

  require Logger

  def index(opts \\ []) do
    opts = Keyword.put_new(opts, :backend, inferred_backend(opts))

    if Keyword.get(opts, :backend) == :duckdb and Keyword.get(opts, :shards, 1) > 1 do
      index_sharded(opts)
    else
      index_single(opts)
    end
  end

  defp index_single(opts) do
    mode = Keyword.get(opts, :mode, :latest)
    concurrency = Keyword.get(opts, :concurrency, 4)
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "hex")
    resume? = Keyword.get(opts, :resume, true)

    entries = list_entries(mode, opts)
    total = length(entries)

    backend = Keyword.fetch!(opts, :backend)

    configure_backend!(backend, repo, opts)
    if Keyword.get(opts, :migrate?, true), do: migrate!(backend, repo, prefix, opts)
    existing = if resume?, do: existing_versions(repo, prefix), else: MapSet.new()

    Progress.start_run(total)
    cli_header(total, mode, MapSet.size(existing))

    counter = :counters.new(1, [:atomics])
    started = System.monotonic_time(:millisecond)

    results =
      entries
      |> Stream.with_index()
      |> Task.async_stream(
        fn {entry, index} ->
          set_dynamic_repo(opts)
          key = {entry.name, entry.version}

          if MapSet.member?(existing, key) do
            :counters.add(counter, 1, 1)
            n = :counters.get(counter, 1)
            Progress.package_done(entry, :skipped)
            {:skipped, entry, n}
          else
            Progress.package_started(entry)

            case index_one(entry, index, opts) do
              :skipped ->
                :counters.add(counter, 1, 1)
                n = :counters.get(counter, 1)
                Progress.package_done(entry, :skipped)
                {:skipped, entry, n}

              result ->
                :counters.add(counter, 1, 1)
                n = :counters.get(counter, 1)
                Progress.package_done(entry, result)
                {result, entry, n}
            end
          end
        end,
        max_concurrency: concurrency,
        timeout: Keyword.get(opts, :timeout, 300_000),
        ordered: false
      )
      |> Enum.reduce(%{ok: 0, skipped: 0, error: 0}, fn
        {:ok, {:ok, entry, count}}, acc ->
          cli_package(entry, count, total, started, :ok)
          %{acc | ok: acc.ok + 1}

        {:ok, {:skipped, entry, count}}, acc ->
          cli_package(entry, count, total, started, :skipped)
          %{acc | skipped: acc.skipped + 1}

        {:ok, {{:error, reason}, entry, count}}, acc ->
          cli_package(entry, count, total, started, {:error, reason})
          %{acc | error: acc.error + 1}

        {:exit, reason}, acc ->
          Logger.error("Task crashed: #{inspect(reason)}")
          %{acc | error: acc.error + 1}
      end)

    finalize_backend!(backend, repo, prefix, opts)

    elapsed = System.monotonic_time(:millisecond) - started
    Progress.finish_run()
    cli_summary(results, elapsed)
    results
  end

  defp index_sharded(opts) do
    shard_count = Keyword.fetch!(opts, :shards)
    mode = Keyword.get(opts, :mode, :latest)
    entries = list_entries(mode, opts)
    entries_by_shard = entries_by_shard(entries, shard_count)
    prefix = Keyword.get(opts, :prefix, "hex")

    {:ok, shards} =
      Exograph.DuckDBShards.start_managed(shard_count,
        directory: Keyword.get_lazy(opts, :shard_directory, &System.tmp_dir!/0),
        prefix: prefix,
        port_base: Keyword.get(opts, :shard_port_base, 9_600),
        duckdb_threads: Keyword.get(opts, :duckdb_threads),
        recovery_mode: Keyword.get(opts, :recovery_mode)
      )

    shards =
      Enum.map(shards, fn shard ->
        shard
        |> Map.put(:entries, Map.fetch!(entries_by_shard, shard.id))
        |> Map.put(:packages, package_keys(Map.fetch!(entries_by_shard, shard.id)))
      end)

    Enum.each(shards, fn shard ->
      Exograph.DuckDBShards.with_repo(shard, fn ->
        Exograph.DuckDB.migrate!(repo: shard.repo, prefix: shard.prefix)
      end)
    end)

    results =
      shards
      |> Task.async_stream(
        fn shard ->
          Exograph.DuckDBShards.with_repo(shard, fn ->
            index_single(
              opts
              |> Keyword.put(:repo, shard.repo)
              |> Keyword.put(:dynamic_repo, shard.dynamic_repo)
              |> Keyword.put(:prefix, shard.prefix)
              |> Keyword.put(:entries, shard.entries)
              |> Keyword.put(:migrate?, false)
              |> Keyword.put(:shards, 1)
            )
          end)
        end,
        max_concurrency: shard_count,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, result} -> result end)

    shard_indexes =
      Enum.map(shards, fn shard ->
        {:ok, index} =
          Exograph.DuckDBShards.with_repo(shard, fn ->
            Exograph.index([],
              backend: :duckdb,
              repo: shard.repo,
              prefix: shard.prefix,
              migrate?: false,
              bm25?: Keyword.get(opts, :bm25?, true),
              duckdb_threads: Keyword.get(opts, :duckdb_threads)
            )
          end)

        Map.put(shard, :index, index)
      end)

    manifest = Exograph.DuckDBShards.manifest(shard_indexes, prefix: prefix)
    write_manifest(manifest, Keyword.get(opts, :manifest_path))

    results
    |> combine_results()
    |> Map.put(:index, Exograph.ShardedIndex.new(shard_indexes, manifest: manifest))
    |> Map.put(:manifest, manifest)
  end

  defp list_entries(mode, opts) do
    case Keyword.fetch(opts, :entries) do
      {:ok, entries} -> entries
      :error -> list_registry_entries(mode, opts)
    end
  end

  defp list_registry_entries(:latest, opts), do: Registry.latest(opts)
  defp list_registry_entries(:top, opts), do: Registry.top(opts)
  defp list_registry_entries(:all, opts), do: Registry.all_versions(opts)

  defp entries_by_shard(entries, shard_count) do
    empty = Map.new(0..(shard_count - 1), &{&1, []})

    entries
    |> Enum.with_index()
    |> Enum.reduce(empty, fn {entry, index}, acc ->
      Map.update!(acc, rem(index, shard_count), &[entry | &1])
    end)
    |> Map.new(fn {index, entries} -> {index, Enum.reverse(entries)} end)
  end

  defp package_keys(entries), do: Enum.map(entries, &Map.take(&1, [:name, :version]))

  defp write_manifest(_manifest, nil), do: :ok

  defp write_manifest(manifest, path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, :erlang.term_to_binary(manifest))
  end

  defp combine_results(results) do
    Enum.reduce(results, %{ok: 0, skipped: 0, error: 0}, fn result, acc ->
      %{
        ok: acc.ok + result.ok,
        skipped: acc.skipped + result.skipped,
        error: acc.error + result.error
      }
    end)
  end

  defp inferred_backend(opts) do
    case Keyword.get(opts, :repo) do
      nil -> :duckdb
      repo when is_atom(repo) -> inferred_repo_backend(repo)
    end
  end

  defp inferred_repo_backend(repo) do
    cond do
      Exograph.Backend.duckdb_repo?(repo) -> :duckdb
      Exograph.Backend.postgres_repo?(repo) -> :postgres
      true -> :duckdb
    end
  end

  defp configure_backend!(:duckdb, repo, opts) do
    set_dynamic_repo(opts)
    Exograph.DuckDB.configure_threads!(repo, Keyword.get(opts, :duckdb_threads))
  end

  defp configure_backend!(_backend, _repo, _opts), do: :ok

  defp migrate!(:duckdb, repo, prefix, _opts) do
    Exograph.DuckDB.migrate!(repo: repo, prefix: prefix)
  end

  defp migrate!(_backend, repo, prefix, opts) do
    Exograph.Postgres.migrate!(
      repo: repo,
      prefix: prefix,
      bm25?: Keyword.get(opts, :bm25?, true),
      postgres_maintenance_work_mem: Keyword.get(opts, :postgres_maintenance_work_mem),
      postgres_max_parallel_maintenance_workers:
        Keyword.get(opts, :postgres_max_parallel_maintenance_workers),
      postgres_unlogged?: Keyword.get(opts, :postgres_unlogged?, false)
    )
  end

  defp finalize_backend!(:duckdb, repo, prefix, opts) do
    if Keyword.get(opts, :bm25?, true) do
      Exograph.DuckDB.create_bm25_indexes!(repo: repo, prefix: prefix)
    else
      Exograph.DuckDB.optimize_structural_indexes!(repo: repo, prefix: prefix)
    end
  end

  defp finalize_backend!(_backend, _repo, _prefix, _opts), do: :ok

  defp existing_versions(repo, prefix) do
    import Ecto.Query

    pv_source = "#{prefix}_package_versions"
    pkg_source = "#{prefix}_packages"

    pkgs =
      from(p in {pkg_source, Exograph.Storage.Ecto.PackageRecord},
        select: %{id: p.id, name: p.name}
      )

    from(pv in {pv_source, Exograph.Storage.Ecto.PackageVersionRecord},
      join: p in subquery(pkgs),
      on: p.id == pv.package_id,
      select: {p.name, pv.version}
    )
    |> repo.all()
    |> MapSet.new()
  end

  defp index_one(entry, index, opts) do
    set_dynamic_repo(opts)
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "hex")
    min_mass = Keyword.get(opts, :min_mass, 8)
    extractors = Keyword.get(opts, :extractors, [:ex_ast])
    download_opts = Keyword.take(opts, [:mirrors, :mirror_strategy, :timeout, :cache_dir])

    try do
      files = Downloader.fetch(entry.name, entry.version, [{:index, index} | download_opts])

      sources =
        files
        |> Enum.filter(fn {path, _source} -> String.ends_with?(path, [".ex", ".exs"]) end)
        |> Enum.map(fn {path, source} -> {safe_path!(path), source} end)

      if sources == [], do: throw(:no_elixir)

      index_opts = [
        backend: Keyword.fetch!(opts, :backend),
        repo: repo,
        prefix: prefix,
        bm25?: Keyword.get(opts, :bm25?, true),
        duckdb_threads: Keyword.get(opts, :duckdb_threads),
        min_mass: min_mass,
        index_concurrency: Keyword.get(opts, :index_concurrency) || System.schedulers_online(),
        migrate?: false,
        extractors: extractors,
        package_version: [
          ecosystem: :hex,
          name: entry.name,
          version: entry.version,
          source_ref: "hex:#{entry.name}:#{entry.version}"
        ]
      ]

      case Exograph.index_sources(sources, index_opts) do
        {:ok, _index} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :no_elixir -> :skipped
    end
  end

  defp safe_path!(path) do
    parts = Path.split(path)

    if Path.type(path) != :relative or ".." in parts or parts == [] do
      raise "unsafe package path #{inspect(path)}"
    end

    Path.join(parts)
  end

  defp set_dynamic_repo(opts) do
    case Keyword.get(opts, :dynamic_repo) do
      nil -> :ok
      dynamic_repo -> Keyword.fetch!(opts, :repo).put_dynamic_repo(dynamic_repo)
    end
  end

  # --- CLI output ---

  defp cli_header(total, mode, existing) do
    IO.puts([
      IO.ANSI.bright(),
      "Exograph Hex Indexer",
      IO.ANSI.reset(),
      "\n  Mode: #{mode}",
      "\n  Packages: #{total}",
      if(existing > 0, do: " (#{existing} already indexed)", else: ""),
      "\n"
    ])
  end

  defp cli_package(entry, count, total, started, status) do
    elapsed_s = (System.monotonic_time(:millisecond) - started) / 1000
    rate = if elapsed_s > 0, do: count / elapsed_s, else: 0.0
    remaining = if rate > 0, do: (total - count) / rate, else: 0.0
    pct = Float.round(count / max(total, 1) * 100, 1)

    {icon, color} =
      case status do
        :ok -> {"✓", IO.ANSI.green()}
        :skipped -> {"○", IO.ANSI.light_black()}
        {:error, _} -> {"✗", IO.ANSI.red()}
      end

    bar = progress_bar(count, total, 30)

    line = [
      "\r",
      IO.ANSI.clear_line(),
      color,
      icon,
      IO.ANSI.reset(),
      " ",
      String.pad_leading("#{count}", String.length("#{total}")),
      "/#{total} ",
      bar,
      " #{pct}% ",
      IO.ANSI.cyan(),
      "#{entry.name}",
      IO.ANSI.reset(),
      "@#{entry.version}"
    ]

    detail =
      case status do
        {:error, reason} ->
          [" ", IO.ANSI.red(), inspect(reason, limit: 60), IO.ANSI.reset()]

        _ ->
          []
      end

    stats = [
      IO.ANSI.light_black(),
      "  #{Float.round(rate, 1)} pkg/s",
      " ETA #{format_duration(remaining)}",
      IO.ANSI.reset()
    ]

    IO.write([line, detail, stats])

    if match?({:error, _}, status), do: IO.puts("")
  end

  defp cli_summary(results, elapsed_ms) do
    IO.puts(["\n\n", IO.ANSI.bright(), "Done", IO.ANSI.reset()])

    IO.puts([
      "  ",
      IO.ANSI.green(),
      "#{results.ok} indexed",
      IO.ANSI.reset(),
      "  ",
      IO.ANSI.light_black(),
      "#{results.skipped} skipped",
      IO.ANSI.reset(),
      if(results.error > 0,
        do: [" ", IO.ANSI.red(), " #{results.error} failed", IO.ANSI.reset()],
        else: []
      ),
      "  in #{format_duration(elapsed_ms / 1000)}"
    ])
  end

  defp progress_bar(current, total, width) do
    filled = if total > 0, do: round(current / total * width), else: 0
    empty = width - filled

    [
      IO.ANSI.green(),
      String.duplicate("█", filled),
      IO.ANSI.light_black(),
      String.duplicate("░", empty),
      IO.ANSI.reset()
    ]
  end

  defp format_duration(seconds), do: Exograph.Duration.format(seconds)
end
