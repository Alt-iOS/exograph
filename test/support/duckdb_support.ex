defmodule Exograph.DuckDBRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :exograph,
    adapter: Ecto.Adapters.QuackDB
end

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

  def opts(prefix, opts \\ []) do
    Keyword.merge(
      [backend: :duckdb, repo: Exograph.DuckDBRepo, prefix: prefix, migrate?: true],
      opts
    )
  end

  def drop_prefix(prefix) do
    Enum.each(
      ~w(call_edges graph_nodes references definitions comments fragments terms files package_versions packages schema_migrations),
      fn suffix ->
        Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_#{suffix}"|, [])
      end
    )
  end
end
