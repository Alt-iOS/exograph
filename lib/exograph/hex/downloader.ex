defmodule Exograph.Hex.Downloader do
  @moduledoc false

  @default_mirrors ["https://repo.hex.pm"]

  def fetch(name, version, opts \\ []) do
    mirrors = Keyword.get(opts, :mirrors, @default_mirrors)
    strategy = Keyword.get(opts, :mirror_strategy, :round_robin)
    index = Keyword.get(opts, :index, 0)
    timeout = Keyword.get(opts, :timeout, 120_000)
    cache_dir = Keyword.get(opts, :cache_dir)

    slug = "#{name}-#{version}"
    cached = if cache_dir, do: Path.join(cache_dir, "#{slug}.tar")

    tarball_bytes =
      if cached && File.exists?(cached) do
        File.read!(cached)
      else
        bytes = download!(name, version, ordered_mirrors(mirrors, strategy, index), timeout)
        if cached, do: write_cached!(cached, bytes)
        bytes
      end

    extract_to_memory(tarball_bytes)
  end

  defp download!(name, version, mirrors, timeout) do
    path = "/tarballs/#{name}-#{version}.tar"

    Enum.reduce_while(mirrors, nil, fn mirror, _acc ->
      url = mirror <> path

      try do
        %{status: status, body: body} =
          Req.get!(url, receive_timeout: timeout, retry: false, decode_body: false)

        if status in 200..299 do
          {:halt, body}
        else
          {:cont, nil}
        end
      rescue
        _error -> {:cont, nil}
      end
    end) || raise "failed to download #{name}-#{version} from all mirrors"
  end

  def extract_to_memory(tarball_bytes) do
    case :hex_tarball.unpack(tarball_bytes, :memory) do
      {:ok, %{contents: contents}} ->
        Enum.map(contents, fn {path, content} ->
          {to_string(path), content}
        end)

      {:error, reason} ->
        raise "hex_tarball.unpack failed: #{inspect(reason)}"
    end
  end

  defp write_cached!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp ordered_mirrors(mirrors, :random, _index) do
    Enum.shuffle(mirrors)
  end

  defp ordered_mirrors(mirrors, _round_robin, index) do
    {tail, head} = Enum.split(mirrors, rem(index, length(mirrors)))
    head ++ tail
  end
end
