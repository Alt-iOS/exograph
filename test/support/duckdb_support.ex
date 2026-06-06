defmodule Exograph.DuckDBSupport do
  @moduledoc false

  def start_repo! do
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:quackdb)

    Application.put_env(:exograph, Exograph.DuckDBRepo,
      uri: System.fetch_env!("QUACKDB_TEST_URI"),
      token: System.get_env("QUACKDB_TEST_TOKEN", ""),
      pool_size: 1,
      log: false
    )

    ExUnit.Callbacks.start_supervised!(Exograph.DuckDBRepo)
  end

  def start_managed_repo!(opts \\ []) do
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:quackdb)

    database =
      Keyword.get_lazy(opts, :database, fn ->
        Path.join(
          System.tmp_dir!(),
          "exograph-duckdb-#{System.unique_integer([:positive])}.duckdb"
        )
      end)

    {:ok, server} = QuackDB.Server.start_link(duckdb: :managed, database: database, token: "test")

    Application.put_env(:exograph, Exograph.DuckDBRepo,
      uri: QuackDB.Server.uri(server),
      token: "test",
      pool_size: 1,
      log: Keyword.get(opts, :log, false),
      timeout: Keyword.get(opts, :timeout, 120_000)
    )

    ExUnit.Callbacks.start_supervised!(Exograph.DuckDBRepo)
    database
  end

  def opts(prefix, opts \\ []) do
    Keyword.merge(
      [backend: :duckdb, repo: Exograph.DuckDBRepo, prefix: prefix, migrate?: true],
      opts
    )
  end

  def drop_prefix(prefix) do
    Enum.each(
      ~w(tree_nodes call_edges graph_nodes references definitions comments fragments fragment_terms terms files package_versions packages schema_migrations),
      fn suffix ->
        Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_#{suffix}"|, [])
      end
    )
  end
end
