defmodule Exograph.DuckDB do
  @moduledoc """
  DuckDB schema helpers for the experimental QuackDB-backed Exograph backend.

  The first DuckDB backend reuses the existing Ecto record modules and store
  logic while replacing the Postgres-only migration/bootstrap layer. Query and
  storage modules can be split further once the backend contract is proven.
  """

  @tables ~w(
    schema_migrations packages package_versions files terms fragments comments definitions
    references graph_nodes call_edges tree_nodes
  )

  @doc "Creates the Exograph DuckDB schema for a prefix."
  def migrate!(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "exograph")

    Enum.each(@tables, &create_sequence!(repo, prefix, &1))

    execute!(repo, """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "schema_migrations")} (
      version BIGINT PRIMARY KEY,
      inserted_at TIMESTAMPTZ DEFAULT now()
    )
    """)

    execute!(repo, """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "packages")} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, "packages")}'),
      ecosystem VARCHAR NOT NULL,
      name VARCHAR NOT NULL,
      metadata JSON NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      UNIQUE (ecosystem, name)
    )
    """)

    execute!(repo, """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "package_versions")} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, "package_versions")}'),
      package_id BIGINT NOT NULL,
      version VARCHAR NOT NULL,
      source_ref VARCHAR,
      checksum VARCHAR,
      metadata JSON NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      UNIQUE (package_id, version)
    )
    """)

    execute!(repo, """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "files")} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, "files")}'),
      package_id BIGINT,
      package_version_id BIGINT,
      path VARCHAR NOT NULL,
      source VARCHAR NOT NULL,
      comments_text VARCHAR NOT NULL DEFAULT '',
      sha256 VARCHAR NOT NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      UNIQUE (package_version_id, sha256)
    )
    """)

    execute!(repo, """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "terms")} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, "terms")}'),
      term VARCHAR NOT NULL UNIQUE
    )
    """)

    execute!(repo, """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "fragments")} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, "fragments")}'),
      package_id BIGINT,
      package_version_id BIGINT,
      file_id BIGINT,
      content_hash BLOB,
      ast BLOB NOT NULL,
      kind VARCHAR NOT NULL,
      module VARCHAR,
      name VARCHAR,
      arity INTEGER,
      line INTEGER NOT NULL,
      end_line INTEGER,
      mass INTEGER NOT NULL,
      exact_hash BLOB,
      terms INTEGER[] NOT NULL DEFAULT [],
      sub_hashes BIGINT[] NOT NULL DEFAULT [],
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      UNIQUE (content_hash)
    )
    """)

    create_fact_tables!(repo, prefix)

    execute!(
      repo,
      "INSERT INTO #{name(prefix, "schema_migrations")} (version) VALUES (1) ON CONFLICT DO NOTHING"
    )

    :ok
  end

  defp create_fact_tables!(repo, prefix) do
    Enum.each(~w(comments definitions references graph_nodes call_edges), fn table ->
      execute!(repo, fact_table_sql(prefix, table))
    end)

    execute!(repo, """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "tree_nodes")} (
      fragment_id BIGINT NOT NULL,
      id INTEGER NOT NULL,
      parent_id INTEGER,
      ordinal INTEGER NOT NULL,
      role VARCHAR,
      kind VARCHAR NOT NULL,
      label VARCHAR,
      line INTEGER NOT NULL,
      preorder INTEGER NOT NULL,
      postorder INTEGER NOT NULL,
      depth INTEGER NOT NULL,
      PRIMARY KEY (fragment_id, id)
    )
    """)
  end

  defp fact_table_sql(prefix, "comments") do
    """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "comments")} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, "comments")}'),
      package_id BIGINT, package_version_id BIGINT, file_id BIGINT NOT NULL,
      fragment_id BIGINT, text VARCHAR NOT NULL, line INTEGER, "column" INTEGER,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """
  end

  defp fact_table_sql(prefix, table) when table in ["definitions", "references"] do
    """
    CREATE TABLE IF NOT EXISTS #{name(prefix, table)} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, table)}'),
      package_id BIGINT, package_version_id BIGINT, file_id BIGINT NOT NULL,
      fragment_id BIGINT, kind VARCHAR NOT NULL, module VARCHAR, name VARCHAR NOT NULL,
      arity INTEGER, qualified_name VARCHAR NOT NULL, line INTEGER, "column" INTEGER,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """
  end

  defp fact_table_sql(prefix, "graph_nodes") do
    """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "graph_nodes")} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, "graph_nodes")}'),
      package_id BIGINT, package_version_id BIGINT, file_id BIGINT, fragment_id BIGINT,
      engine VARCHAR NOT NULL, external_id VARCHAR, kind VARCHAR NOT NULL, module VARCHAR,
      name VARCHAR, arity INTEGER, qualified_name VARCHAR NOT NULL, line INTEGER, "column" INTEGER,
      metadata JSON NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """
  end

  defp fact_table_sql(prefix, "call_edges") do
    """
    CREATE TABLE IF NOT EXISTS #{name(prefix, "call_edges")} (
      id BIGINT PRIMARY KEY DEFAULT nextval('#{sequence(prefix, "call_edges")}'),
      package_id BIGINT, package_version_id BIGINT, file_id BIGINT,
      caller_node_id BIGINT NOT NULL, callee_node_id BIGINT NOT NULL,
      call_site_fragment_id BIGINT, caller_qualified_name VARCHAR NOT NULL,
      callee_qualified_name VARCHAR NOT NULL, line INTEGER, "column" INTEGER,
      metadata JSON NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """
  end

  defp create_sequence!(repo, prefix, table) do
    execute!(repo, "CREATE SEQUENCE IF NOT EXISTS #{sequence(prefix, table)}")
  end

  defp execute!(repo, sql), do: repo.query!(sql, [])
  defp name(prefix, suffix), do: ~s("#{prefix}_#{suffix}")
  defp sequence(prefix, suffix), do: "#{prefix}_#{suffix}_id_seq"
end
