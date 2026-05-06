defmodule Exograph.Postgres do
  @moduledoc """
  Ecto/Postgres helpers for the durable Exograph backend.

  Relational storage is created through Ecto migrations. Raw SQL is reserved for
  Postgres extensions and ParadeDB's BM25 index, which Ecto migrations do not
  model directly.
  """

  alias Ecto.Migration.Runner
  alias Exograph.Postgres.Migrations.CreateSchema

  @schema_version 1

  @type repo :: module()
  @type backend_opts :: [repo: repo(), prefix: String.t(), bm25?: boolean()]

  @doc """
  Creates or upgrades the Exograph Postgres schema.

  Options:

    * `:repo` - an Ecto repo module (required)
    * `:prefix` - table-name prefix, defaults to `"exograph"`
    * `:bm25?` - create a ParadeDB BM25 index when `pg_search` is available,
      defaults to `true`
  """
  @spec migrate!(backend_opts()) :: :ok
  def migrate!(opts) do
    repo = fetch_repo!(opts)
    prefix = Keyword.get(opts, :prefix, "exograph")
    bm25? = Keyword.get(opts, :bm25?, true)

    execute!(repo, "CREATE EXTENSION IF NOT EXISTS pgcrypto", [])
    if bm25?, do: execute!(repo, "CREATE EXTENSION IF NOT EXISTS pg_search", [])

    Application.put_env(:exograph, CreateSchema, prefix: prefix)

    Runner.run(repo, repo.config(), @schema_version, CreateSchema, :forward, :up, :up,
      log: false,
      log_migrations_sql: false
    )

    execute!(
      repo,
      "INSERT INTO #{table(prefix, "schema_migrations")} (version) VALUES ($1) ON CONFLICT DO NOTHING",
      [@schema_version]
    )

    if bm25?, do: create_bm25_index!(repo, prefix)

    :ok
  end

  defp create_bm25_index!(repo, prefix) do
    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_fragments_bm25_idx
      ON #{table(prefix, "fragments")}
      USING bm25 (id, source, file, kind, name, package_id, package_version_id, terms_text, defs_text, refs_text, modules_text, functions_text, aliases_text, structs_text, atoms_text)
      WITH (key_field = 'id')
      """,
      []
    )
  end

  @doc false
  def fetch_repo!(opts), do: Keyword.fetch!(opts, :repo)

  @doc false
  def table(prefix, name), do: ~s("#{prefix}_#{name}")

  @doc false
  def execute!(repo, sql, params) do
    Ecto.Adapters.SQL.query!(repo, sql, params)
    :ok
  end

  @doc false
  def query(repo, sql, params \\ []), do: Ecto.Adapters.SQL.query(repo, sql, params)
end
