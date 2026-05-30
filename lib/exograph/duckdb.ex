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

  @doc "Creates DuckDB FTS/BM25 indexes for searchable Exograph tables."
  def create_bm25_indexes!(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "exograph")

    execute_optional!(repo, QuackDB.FTS.install())
    execute_optional!(repo, QuackDB.FTS.load())

    create_fts_index!(repo, prefix, "files", :id, [:source, :comments_text])
    create_fts_index!(repo, prefix, "fragments", :id, [:name, :module, :kind])
    create_fts_index!(repo, prefix, "comments", :id, [:text])
    create_fts_index!(repo, prefix, "definitions", :id, [:name, :module, :qualified_name, :kind])
    create_fts_index!(repo, prefix, "references", :id, [:name, :module, :qualified_name, :kind])

    :ok
  end

  defp create_fts_index!(repo, prefix, table, id_column, columns) do
    repo.query!(
      QuackDB.FTS.create_index("#{prefix}_#{table}", id_column, columns, overwrite: true),
      []
    )
  end

  defp execute_optional!(repo, statement) do
    repo.query!(statement, [])
    :ok
  rescue
    QuackDB.Error -> :ok
  end
end
