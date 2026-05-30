defmodule Exograph.DuckDB do
  @moduledoc """
  DuckDB schema helpers for the experimental QuackDB-backed Exograph backend.
  """

  alias Ecto.Migration.Runner
  alias Exograph.Postgres.Migrations.CreateSchema

  @doc "Creates the Exograph DuckDB schema for a prefix."
  def migrate!(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "exograph")

    Application.put_env(:exograph, CreateSchema, prefix: prefix, backend: :duckdb)

    Runner.run(repo, repo.config(), 1, CreateSchema, :forward, :up, :up,
      log: false,
      log_migrations_sql: false
    )

    repo.insert_all(
      {"#{prefix}_schema_migrations", Exograph.Postgres.SchemaMigration},
      [%{version: 1}],
      conflict_target: [:version],
      on_conflict: :nothing
    )

    :ok
  end
end
