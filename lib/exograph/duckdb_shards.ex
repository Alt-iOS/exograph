defmodule Exograph.DuckDBShards do
  @moduledoc false

  def start_managed(count, opts \\ []) when count > 0 do
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:quackdb)

    directory = Keyword.get_lazy(opts, :directory, &System.tmp_dir!/0)
    File.mkdir_p!(directory)

    prefix = Keyword.get(opts, :prefix, "exograph_shard")
    port_base = Keyword.get(opts, :port_base, 9_600)
    duckdb_threads = Keyword.get(opts, :duckdb_threads)

    shards =
      Enum.map(0..(count - 1), fn index ->
        database = database_path(Keyword.get(opts, :database), directory, prefix, index)
        token = Keyword.get(opts, :token, "exograph-shard-#{System.unique_integer([:positive])}")
        endpoint = "quack:localhost:#{port_base + index}"

        {:ok, server} =
          QuackDB.Server.start_link(
            duckdb: Keyword.get(opts, :duckdb, :managed),
            database: database,
            endpoint: endpoint,
            token: token,
            settings: duckdb_settings(duckdb_threads)
          )

        name = unique_repo_name()
        uri = QuackDB.Server.uri(server)
        dynamic_repo = start_repo!(name, uri, token, Keyword.get(opts, :pool_size, 1))

        %{
          id: index,
          repo: Exograph.DuckDBRepo,
          dynamic_repo: dynamic_repo,
          prefix: "#{prefix}_#{index}",
          database: database,
          uri: uri,
          token: token,
          server: server,
          packages: []
        }
      end)

    {:ok, shards}
  end

  def open(manifest, opts \\ []) do
    shards = Map.fetch!(manifest, :shards)
    port_base = Keyword.get(opts, :port_base, 9_700)
    duckdb_threads = Keyword.get(opts, :duckdb_threads)

    opened =
      Enum.map(shards, fn shard ->
        id = Map.fetch!(shard, :id)
        token = Keyword.get(opts, :token, "exograph-shard-#{System.unique_integer([:positive])}")
        endpoint = "quack:localhost:#{port_base + id}"

        {:ok, server} =
          QuackDB.Server.start_link(
            duckdb: Keyword.get(opts, :duckdb, :managed),
            database: Map.fetch!(shard, :database),
            endpoint: endpoint,
            token: token,
            settings: duckdb_settings(duckdb_threads)
          )

        name = unique_repo_name()
        uri = QuackDB.Server.uri(server)
        dynamic_repo = start_repo!(name, uri, token, Keyword.get(opts, :pool_size, 1))

        shard
        |> Map.put(:repo, Exograph.DuckDBRepo)
        |> Map.put(:dynamic_repo, dynamic_repo)
        |> Map.put(:uri, uri)
        |> Map.put(:token, token)
        |> Map.put(:server, server)
      end)

    {:ok, opened}
  end

  def with_repo(%{dynamic_repo: dynamic_repo}, fun) when is_function(fun, 0) do
    previous = Exograph.DuckDBRepo.get_dynamic_repo()
    Exograph.DuckDBRepo.put_dynamic_repo(dynamic_repo)

    try do
      fun.()
    after
      Exograph.DuckDBRepo.put_dynamic_repo(previous)
    end
  end

  def with_repo(_shard, fun) when is_function(fun, 0), do: fun.()

  def manifest(shards, opts \\ []) do
    %{
      version: 1,
      backend: :duckdb,
      shard_count: length(shards),
      prefix: Keyword.get(opts, :prefix),
      shards:
        Enum.map(shards, fn shard ->
          %{
            id: shard.id,
            prefix: shard.prefix,
            database: shard.database,
            packages: Map.get(shard, :packages, [])
          }
        end)
    }
  end

  defp database_path(nil, directory, prefix, index) do
    Path.join(directory, "#{prefix}_#{index}.duckdb")
  end

  defp database_path(paths, _directory, _prefix, index) when is_list(paths),
    do: Enum.at(paths, index)

  defp database_path(path, _directory, _prefix, _index) when is_binary(path), do: path

  defp duckdb_settings(nil), do: [threads: System.schedulers_online()]
  defp duckdb_settings(threads), do: [threads: threads]

  defp unique_repo_name do
    :erlang.unique_integer([:positive])
    |> then(&:"exograph_duckdb_shard_#{&1}")
  end

  defp start_repo!(name, uri, token, pool_size) do
    config = [
      name: name,
      uri: uri,
      token: token,
      pool_size: pool_size,
      log: false,
      timeout: 120_000
    ]

    case Exograph.DuckDBRepo.start_link(config) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
