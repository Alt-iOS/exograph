defmodule Exograph.Postgres do
  @moduledoc """
  Ecto/Postgres helpers for the durable Exograph backend.

  The backend stores fragments, structural terms, symbols, and AST tree nodes in
  normal Postgres tables. When `pg_search` from ParadeDB is installed, the
  fragment table also gets a BM25 covering index over source and candidate term
  fields.
  """

  @schema_version 1

  @type repo :: module()
  @type backend_opts :: [repo: repo(), prefix: String.t(), bm25?: boolean()]

  @doc """
  Creates or upgrades the Exograph Postgres schema through `Ecto.Adapters.SQL`.

  Options:

    * `:repo` - an Ecto repo module (required)
    * `:prefix` - table prefix, defaults to `"exograph"`
    * `:bm25?` - create a ParadeDB BM25 index when `pg_search` is available,
      defaults to `true`
  """
  @spec migrate!(backend_opts()) :: :ok
  def migrate!(opts) do
    repo = fetch_repo!(opts)
    prefix = Keyword.get(opts, :prefix, "exograph")
    bm25? = Keyword.get(opts, :bm25?, true)

    execute!(repo, "CREATE EXTENSION IF NOT EXISTS pgcrypto", [])

    if bm25? do
      execute!(repo, "CREATE EXTENSION IF NOT EXISTS pg_search", [])
    end

    execute!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS #{table(prefix, "schema_migrations")} (
        version integer PRIMARY KEY,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    execute!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS #{table(prefix, "fragments")} (
        id text PRIMARY KEY,
        file text NOT NULL,
        source text,
        ast bytea NOT NULL,
        kind text NOT NULL,
        module text,
        name text,
        arity integer,
        line integer NOT NULL,
        end_line integer,
        mass integer NOT NULL,
        exact_hash text,
        abstract_hash text,
        terms text[] NOT NULL DEFAULT '{}',
        terms_text text NOT NULL DEFAULT '',
        sub_hashes bigint[] NOT NULL DEFAULT '{}',
        defs text[] NOT NULL DEFAULT '{}',
        defs_text text NOT NULL DEFAULT '',
        refs text[] NOT NULL DEFAULT '{}',
        refs_text text NOT NULL DEFAULT '',
        modules text[] NOT NULL DEFAULT '{}',
        modules_text text NOT NULL DEFAULT '',
        functions text[] NOT NULL DEFAULT '{}',
        functions_text text NOT NULL DEFAULT '',
        aliases text[] NOT NULL DEFAULT '{}',
        aliases_text text NOT NULL DEFAULT '',
        structs text[] NOT NULL DEFAULT '{}',
        structs_text text NOT NULL DEFAULT '',
        atoms text[] NOT NULL DEFAULT '{}',
        atoms_text text NOT NULL DEFAULT '',
        inserted_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    execute!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS #{table(prefix, "tree_nodes")} (
        fragment_id text NOT NULL REFERENCES #{table(prefix, "fragments")}(id) ON DELETE CASCADE,
        id integer NOT NULL,
        parent_id integer,
        ordinal integer NOT NULL,
        role text,
        kind text NOT NULL,
        label text,
        line integer NOT NULL,
        preorder integer NOT NULL,
        postorder integer NOT NULL,
        depth integer NOT NULL,
        PRIMARY KEY (fragment_id, id)
      )
      """,
      []
    )

    execute!(
      repo,
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_terms_gin ON #{table(prefix, "fragments")} USING gin (terms)",
      []
    )

    execute!(
      repo,
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_file_idx ON #{table(prefix, "fragments")} (file)",
      []
    )

    execute!(
      repo,
      "CREATE INDEX IF NOT EXISTS #{prefix}_tree_nodes_fragment_idx ON #{table(prefix, "tree_nodes")} (fragment_id)",
      []
    )

    if bm25? do
      execute!(
        repo,
        """
        CREATE INDEX IF NOT EXISTS #{prefix}_fragments_bm25_idx
        ON #{table(prefix, "fragments")}
        USING bm25 (id, source, file, kind, name, terms_text, defs_text, refs_text, modules_text, functions_text, aliases_text, structs_text, atoms_text)
        WITH (key_field = 'id')
        """,
        []
      )
    end

    execute!(
      repo,
      "INSERT INTO #{table(prefix, "schema_migrations")} (version) VALUES ($1) ON CONFLICT DO NOTHING",
      [@schema_version]
    )

    :ok
  end

  @doc false
  def fetch_repo!(opts) do
    Keyword.fetch!(opts, :repo)
  end

  @doc false
  def table(prefix, name), do: ~s("#{prefix}_#{name}")

  @doc false
  def execute!(repo, sql, params) do
    Ecto.Adapters.SQL.query!(repo, sql, params)
    :ok
  end

  @doc false
  def query(repo, sql, params \\ []) do
    Ecto.Adapters.SQL.query(repo, sql, params)
  end
end
