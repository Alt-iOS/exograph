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
  @type backend_opts :: [
          repo: repo(),
          prefix: String.t(),
          bm25?: boolean(),
          postgres_maintenance_work_mem: String.t() | nil,
          postgres_max_parallel_maintenance_workers: non_neg_integer() | nil,
          postgres_unlogged?: boolean(),
          postgres_defer_indexes?: boolean()
        ]

  @tables ~w(files fragments terms fragment_terms comments definitions references graph_nodes call_edges tree_nodes packages package_versions)

  @doc """
  Creates or upgrades the Exograph Postgres schema.

  Options:

    * `:repo` - an Ecto repo module (required)
    * `:prefix` - table-name prefix, defaults to `"exograph"`
    * `:bm25?` - create a ParadeDB BM25 index when `pg_search` is available,
      defaults to `true`
    * `:postgres_maintenance_work_mem` - session-local `maintenance_work_mem`
      while creating indexes
    * `:postgres_max_parallel_maintenance_workers` - session-local
      `max_parallel_maintenance_workers` while creating indexes
    * `:postgres_unlogged?` - create Exograph tables as `UNLOGGED` for
      rebuildable local benchmark/index workloads
    * `:postgres_defer_indexes?` - defer non-unique query index creation until
      `finalize!/1`, preserving uniqueness constraints needed for upserts
  """
  @spec migrate!(backend_opts()) :: :ok
  def migrate!(opts) do
    repo = fetch_repo!(opts)
    prefix = Keyword.get(opts, :prefix, "exograph")
    bm25? = Keyword.get(opts, :bm25?, true)

    execute!(repo, "CREATE EXTENSION IF NOT EXISTS pgcrypto", [])
    execute!(repo, "CREATE EXTENSION IF NOT EXISTS pg_trgm", [])
    if bm25?, do: execute!(repo, "CREATE EXTENSION IF NOT EXISTS pg_search", [])

    with_index_build_settings(repo, opts, fn ->
      run_migration!(repo, prefix, CreateSchema, opts)

      unless Keyword.get(opts, :postgres_defer_indexes?, false) do
        create_trgm_indexes!(repo, prefix)
        if bm25?, do: create_bm25_indexes!(repo, prefix)
      end
    end)

    :ok
  end

  defp run_migration!(repo, prefix, module, opts) do
    Application.put_env(:exograph, module,
      prefix: prefix,
      backend: :postgres,
      postgres_unlogged?: Keyword.get(opts, :postgres_unlogged?, false),
      postgres_defer_indexes?: Keyword.get(opts, :postgres_defer_indexes?, false)
    )

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

  @doc false
  def finalize!(opts) do
    repo = fetch_repo!(opts)
    prefix = Keyword.get(opts, :prefix, "exograph")

    with_index_build_settings(repo, opts, fn ->
      create_standard_indexes!(repo, prefix)
      create_trgm_indexes!(repo, prefix)
      if Keyword.get(opts, :bm25?, true), do: create_bm25_indexes!(repo, prefix)
    end)

    analyze!(repo, prefix)
  end

  @doc false
  def analyze!(repo, prefix) do
    Enum.each(@tables, fn table ->
      execute!(repo, "ANALYZE #{Exograph.Storage.Ecto.SQL.table(prefix, table)}", [])
    end)

    :ok
  end

  defp create_standard_indexes!(repo, prefix) do
    standard_indexes(prefix)
    |> Enum.each(fn sql -> execute!(repo, sql, []) end)
  end

  defp standard_indexes(prefix) do
    table = &Exograph.Storage.Ecto.SQL.table(prefix, &1)

    [
      "CREATE INDEX IF NOT EXISTS #{prefix}_files_package_path_idx ON #{table.("files")} (package_version_id, path)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_terms_gin_idx ON #{table.("fragments")} USING gin (terms)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_package_idx ON #{table.("fragments")} (package_id, package_version_id)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_file_idx ON #{table.("fragments")} (file_id)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_file_line_idx ON #{table.("fragments")} (file_id, line)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_file_kind_line_idx ON #{table.("fragments")} (file_id, kind, line)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_kind_name_arity_idx ON #{table.("fragments")} (kind, name, arity)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_fragments_containment_idx ON #{table.("fragments")} (file_id, line, end_line) WHERE kind IN ('def','defp','defmacro','defmacrop')",
      "CREATE INDEX IF NOT EXISTS #{prefix}_comments_file_idx ON #{table.("comments")} (file_id)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_comments_fragment_idx ON #{table.("comments")} (fragment_id)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_definitions_qualified_idx ON #{table.("definitions")} (qualified_name)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_definitions_fragment_idx ON #{table.("definitions")} (fragment_id)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_definitions_file_line_idx ON #{table.("definitions")} (file_id, line)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_references_qualified_idx ON #{table.("references")} (qualified_name)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_references_fragment_idx ON #{table.("references")} (fragment_id)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_references_file_line_idx ON #{table.("references")} (file_id, line)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_graph_nodes_qualified_idx ON #{table.("graph_nodes")} (qualified_name)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_graph_nodes_file_idx ON #{table.("graph_nodes")} (file_id)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_call_edges_caller_idx ON #{table.("call_edges")} (caller_qualified_name)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_call_edges_callee_idx ON #{table.("call_edges")} (callee_qualified_name)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_call_edges_file_idx ON #{table.("call_edges")} (file_id)",
      "CREATE INDEX IF NOT EXISTS #{prefix}_tree_nodes_fragment_idx ON #{table.("tree_nodes")} (fragment_id)"
    ]
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

  defp with_index_build_settings(repo, opts, fun) do
    maintenance_work_mem = Keyword.get(opts, :postgres_maintenance_work_mem)
    parallel_workers = Keyword.get(opts, :postgres_max_parallel_maintenance_workers)

    if maintenance_work_mem || parallel_workers do
      repo.transaction(
        fn ->
          if maintenance_work_mem do
            repo.query!("SELECT set_config('maintenance_work_mem', $1, true)", [
              maintenance_work_mem
            ])
          end

          if parallel_workers do
            repo.query!("SELECT set_config('max_parallel_maintenance_workers', $1, true)", [
              to_string(parallel_workers)
            ])
          end

          fun.()
        end,
        timeout: :infinity
      )
    else
      fun.()
    end

    :ok
  end

  @doc false
  def fetch_repo!(opts), do: Keyword.fetch!(opts, :repo)

  @doc false
  def execute!(repo, sql, params) do
    Ecto.Adapters.SQL.query!(repo, sql, params)
    :ok
  end
end
