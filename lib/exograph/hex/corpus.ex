defmodule Exograph.Hex.Corpus do
  @moduledoc false

  alias Exograph.Hex.{Downloader, Registry}

  require Logger

  def index(opts \\ []) do
    mode = Keyword.get(opts, :mode, :latest)
    concurrency = Keyword.get(opts, :concurrency, 4)
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "hex")
    resume? = Keyword.get(opts, :resume, true)

    entries = list_entries(mode, opts)
    total = length(entries)
    Logger.info("Found #{total} packages to index (mode=#{mode})")

    migrate!(repo, prefix, opts)
    existing = if resume?, do: existing_versions(repo, prefix), else: MapSet.new()

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
            {:skipped, entry, :counters.get(counter, 1)}
          else
            case index_one(entry, index, opts) do
              :skipped ->
                :counters.add(counter, 1, 1)
                {:skipped, entry, :counters.get(counter, 1)}

              result ->
                :counters.add(counter, 1, 1)
                {result, entry, :counters.get(counter, 1)}
            end
          end
        end,
        max_concurrency: concurrency,
        timeout: Keyword.get(opts, :timeout, 300_000),
        ordered: false
      )
      |> Enum.reduce(%{ok: 0, skipped: 0, error: 0}, fn
        {:ok, {:ok, entry, count}}, acc ->
          log_progress(entry, count, total, started, :ok)
          %{acc | ok: acc.ok + 1}

        {:ok, {:skipped, entry, count}}, acc ->
          log_progress(entry, count, total, started, :skipped)
          %{acc | skipped: acc.skipped + 1}

        {:ok, {{:error, reason}, entry, count}}, acc ->
          log_progress(entry, count, total, started, {:error, reason})
          %{acc | error: acc.error + 1}

        {:exit, reason}, acc ->
          Logger.error("Task crashed: #{inspect(reason)}")
          %{acc | error: acc.error + 1}
      end)

    elapsed = System.monotonic_time(:millisecond) - started
    Logger.info("Done in #{Float.round(elapsed / 1000, 1)}s — #{inspect(results)}")
    results
  end

  defp list_entries(:latest, opts), do: Registry.latest(opts)
  defp list_entries(:top, opts), do: Registry.top(opts)
  defp list_entries(:all, opts), do: Registry.all_versions(opts)

  defp migrate!(repo, prefix, opts) do
    bm25? = Keyword.get(opts, :bm25?, false)
    Exograph.Postgres.migrate!(repo: repo, prefix: prefix, bm25?: bm25?)
  end

  defp existing_versions(repo, prefix) do
    import Ecto.Query

    pv_source = "#{prefix}_package_versions"
    pkg_source = "#{prefix}_packages"

    pkgs =
      from(p in {pkg_source, Exograph.Postgres.PackageRecord}, select: %{id: p.id, name: p.name})

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
        repo: repo,
        prefix: prefix,
        bm25?: false,
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
    catch
      :no_elixir -> :skipped
    rescue
      error -> {:error, Exception.message(error)}
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

  defp log_progress(entry, count, total, started, status) do
    elapsed_s = (System.monotonic_time(:millisecond) - started) / 1000
    rate = if elapsed_s > 0, do: Float.round(count / elapsed_s, 1), else: 0.0

    status_str =
      case status do
        :ok -> "indexed"
        :skipped -> "skipped"
        {:error, reason} -> "FAILED: #{inspect(reason, limit: 80)}"
      end

    if rem(count, 50) == 0 or match?({:error, _}, status) do
      Logger.info(
        "[#{count}/#{total}] #{entry.name}@#{entry.version} #{status_str} (#{rate} pkg/s)"
      )
    end
  end
end
