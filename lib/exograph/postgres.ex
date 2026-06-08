defmodule Exograph.Postgres do
  @moduledoc """
  Ecto/Postgres helpers for the durable Exograph backend.

  Relational storage is created through Ecto migrations. Raw SQL is reserved for
  Postgres extensions and ParadeDB's BM25 index, which Ecto migrations do not
  model directly.
  """

  alias Ecto.Migration.Runner
  alias Exograph.Storage.Ecto.Migrations.CreateSchema

  defmodule SchemaMigration do
    @moduledoc false

    use Ecto.Schema

    @primary_key false
    schema "schema_migrations" do
      field(:version, :integer, primary_key: true)
    end
  end

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
    execute!(repo, "CREATE EXTENSION IF NOT EXISTS pg_trgm", [])
    if bm25?, do: execute!(repo, "CREATE EXTENSION IF NOT EXISTS pg_search", [])

    run_migration!(repo, prefix, CreateSchema)

    create_trgm_indexes!(repo, prefix)
    if bm25?, do: create_bm25_indexes!(repo, prefix)

    :ok
  end

  defp run_migration!(repo, prefix, module) do
    Application.put_env(:exograph, module, prefix: prefix, backend: :postgres)

    Runner.run(repo, repo.config(), 1, module, :forward, :up, :up,
      log: false,
      log_migrations_sql: false
    )

    repo.insert_all(
      {"#{prefix}_schema_migrations", SchemaMigration},
      [%{version: 1}],
      conflict_target: [:version],
      on_conflict: :nothing
    )
  end

  defp create_trgm_indexes!(repo, prefix) do
    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_files_source_trgm_idx
      ON #{prefix}_files USING gin (source gin_trgm_ops)
      """,
      []
    )

    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_files_comments_trgm_idx
      ON #{prefix}_files USING gin (comments_text gin_trgm_ops)
      WHERE comments_text IS NOT NULL
      """,
      []
    )
  end

  defp create_bm25_indexes!(repo, prefix) do
    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_files_bm25_idx
      ON #{Exograph.Storage.Ecto.SQL.table(prefix, "files")}
      USING bm25 (
        id,
        (source::pdb.source_code),
        (comments_text::pdb.unicode_words),
        (path::pdb.literal)
      )
      WITH (key_field = 'id')
      """,
      []
    )

    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_fragments_bm25_idx
      ON #{Exograph.Storage.Ecto.SQL.table(prefix, "fragments")}
      USING bm25 (
        id,
        (name::pdb.ngram(2, 32, 'prefix_only=true')),
        (module::pdb.ngram(2, 64, 'prefix_only=true')),
        (kind::pdb.literal)
      )
      WITH (key_field = 'id')
      """,
      []
    )

    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_comments_bm25_idx
      ON #{Exograph.Storage.Ecto.SQL.table(prefix, "comments")}
      USING bm25 (
        id,
        (text::pdb.unicode_words)
      )
      WITH (key_field = 'id')
      """,
      []
    )

    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_definitions_bm25_idx
      ON #{Exograph.Storage.Ecto.SQL.table(prefix, "definitions")}
      USING bm25 (
        id,
        (name::pdb.ngram(2, 32, 'prefix_only=true')),
        (module::pdb.ngram(2, 64, 'prefix_only=true')),
        (qualified_name::pdb.ngram(2, 96, 'prefix_only=true')),
        (kind::pdb.literal)
      )
      WITH (key_field = 'id')
      """,
      []
    )

    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_references_bm25_idx
      ON #{Exograph.Storage.Ecto.SQL.table(prefix, "references")}
      USING bm25 (
        id,
        (name::pdb.ngram(2, 32, 'prefix_only=true')),
        (module::pdb.ngram(2, 64, 'prefix_only=true')),
        (qualified_name::pdb.ngram(2, 96, 'prefix_only=true')),
        (kind::pdb.literal)
      )
      WITH (key_field = 'id')
      """,
      []
    )
  end

  @doc false
  def fetch_repo!(opts), do: Keyword.fetch!(opts, :repo)

  @doc false
  def execute!(repo, sql, params) do
    Ecto.Adapters.SQL.query!(repo, sql, params)
    :ok
  end
end
