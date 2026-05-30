defmodule Exograph.Hex.Corpus do
  @moduledoc false

  alias Exograph.Hex.{Downloader, Progress, Registry}

  require Logger

  def index(opts \\ []) do
    mode = Keyword.get(opts, :mode, :latest)
    concurrency = Keyword.get(opts, :concurrency, 4)
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "hex")
    resume? = Keyword.get(opts, :resume, true)

    entries = list_entries(mode, opts)
    total = length(entries)

    backend = Keyword.get(opts, :backend, :postgres)

    migrate!(backend, repo, prefix, opts)
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

    elapsed = System.monotonic_time(:millisecond) - started
    Progress.finish_run()
    cli_summary(results, elapsed)
    results
  end

  defp list_entries(:latest, opts), do: Registry.latest(opts)
  defp list_entries(:top, opts), do: Registry.top(opts)
  defp list_entries(:all, opts), do: Registry.all_versions(opts)

  defp migrate!(:duckdb, repo, prefix, _opts) do
    Exograph.DuckDB.migrate!(repo: repo, prefix: prefix)
  end

  defp migrate!(_backend, repo, prefix, opts) do
    bm25? = Keyword.get(opts, :bm25?, true)
    Exograph.Postgres.migrate!(repo: repo, prefix: prefix, bm25?: bm25?)
  end

  defp existing_versions(repo, prefix) do
    import Ecto.Query

    pv_source = "#{prefix}_package_versions"
    pkg_source = "#{prefix}_packages"

    pkgs =
      from(p in {pkg_source, Exograph.Postgres.PackageRecord},
        select: %{id: p.id, name: p.name}
      )

    from(pv in {pv_source, Exograph.Postgres.PackageVersionRecord},
      join: p in subquery(pkgs),
      on: p.id == pv.package_id,
      select: {p.name, pv.version}
    )
    |> repo.all()
    |> MapSet.new()
  end

  defp index_one(entry, index, opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "hex")
    min_mass = Keyword.get(opts, :min_mass, 8)
    extractors = Keyword.get(opts, :extractors, [:ex_ast])
    download_opts = Keyword.take(opts, [:mirrors, :mirror_strategy, :timeout, :cache_dir])

    tmp_dir = Path.join(System.tmp_dir!(), "exograph-hex-#{entry.name}-#{entry.version}")

    try do
      files = Downloader.fetch(entry.name, entry.version, [{:index, index} | download_opts])
      has_elixir? = Enum.any?(files, fn {path, _} -> String.ends_with?(path, ".ex") end)
      unless has_elixir?, do: throw(:no_elixir)
      write_files!(tmp_dir, files)

      index_opts = [
        backend: Keyword.get(opts, :backend, :postgres),
        repo: repo,
        prefix: prefix,
        bm25?: Keyword.get(opts, :bm25?, true),
        min_mass: min_mass,
        migrate?: false,
        extractors: extractors,
        package_version: [
          ecosystem: :hex,
          name: entry.name,
          version: entry.version,
          source_ref: "hex:#{entry.name}:#{entry.version}"
        ]
      ]

      case Exograph.index(tmp_dir, index_opts) do
        {:ok, _index} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :no_elixir -> :skipped
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp write_files!(dir, files) do
    File.mkdir_p!(dir)

    Enum.each(files, fn {path, content} ->
      output = Path.join(dir, safe_path!(path))
      File.mkdir_p!(Path.dirname(output))
      File.write!(output, content)
    end)
  end

  defp safe_path!(path) do
    parts = Path.split(path)

    if Path.type(path) != :relative or ".." in parts or parts == [] do
      raise "unsafe package path #{inspect(path)}"
    end

    Path.join(parts)
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

  defp format_duration(seconds) when seconds < 60, do: "#{round(seconds)}s"

  defp format_duration(seconds) when seconds < 3600 do
    m = div(round(seconds), 60)
    s = rem(round(seconds), 60)
    "#{m}m#{String.pad_leading("#{s}", 2, "0")}s"
  end

  defp format_duration(seconds) do
    h = div(round(seconds), 3600)
    m = div(rem(round(seconds), 3600), 60)
    "#{h}h#{String.pad_leading("#{m}", 2, "0")}m"
  end
end
