defmodule Exograph.Postgres do
  @moduledoc """
  Ecto/Postgres helpers for the durable Exograph backend.

  Relational storage is created through Ecto migrations. Raw SQL is reserved for
  Postgres extensions and ParadeDB's BM25 index, which Ecto migrations do not
  model directly.
  """

  alias Ecto.Migration.Runner
  alias Exograph.Postgres.Migrations.CreateSchema

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
    if bm25?, do: execute!(repo, "CREATE EXTENSION IF NOT EXISTS pg_search", [])

    run_migration!(repo, prefix, CreateSchema)

    if bm25?, do: create_bm25_indexes!(repo, prefix)

    :ok
  end

  defp run_migration!(repo, prefix, module) do
    Application.put_env(:exograph, module, prefix: prefix)

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

  defp create_bm25_indexes!(repo, prefix) do
    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_files_bm25_idx
      ON #{table(prefix, "files")}
      USING bm25 (
        id,
        (source::pdb.source_code),
        (comments_text::pdb.unicode),
        (path::pdb.literal),
        (package_id::pdb.literal),
        (package_version_id::pdb.literal)
      )
      WITH (key_field = 'id')
      """,
      []
    )

    execute!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS #{prefix}_fragments_bm25_idx
      ON #{table(prefix, "fragments")}
      USING bm25 (
        id,
        (name::pdb.edge_ngram(2, 32, 'token_chars=letter,digit,punctuation')),
        (module::pdb.edge_ngram(2, 64, 'token_chars=letter,digit,punctuation')),
        (kind::pdb.literal),
        (package_id::pdb.literal),
        (package_version_id::pdb.literal)
      )
      WITH (key_field = 'id')
      """,
      []
    )
  end

  @doc false
  def fetch_repo!(opts), do: Keyword.fetch!(opts, :repo)

  @doc false
  def bulk_insert_all(repo, source, entries, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 1_000)
    max_concurrency = Keyword.get_lazy(opts, :max_concurrency, fn -> repo_pool_size(repo) end)
    insert_opts = Keyword.drop(opts, [:chunk_size, :max_concurrency])

    entries
    |> Enum.chunk_every(chunk_size)
    |> insert_chunks(repo, source, insert_opts, max_concurrency)
  end

  @doc false
  def table(prefix, name), do: ~s("#{prefix}_#{name}")

  defp insert_chunks([], _repo, _source, _opts, _max_concurrency), do: :ok

  defp insert_chunks([chunk], repo, source, opts, _max_concurrency) do
    repo.insert_all(source, chunk, opts)
    :ok
  end

  defp insert_chunks(chunks, repo, source, opts, max_concurrency) do
    chunks
    |> Task.async_stream(
      fn chunk -> repo.insert_all(source, chunk, opts) end,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.each(fn
      {:ok, _result} -> :ok
      {:exit, reason} -> exit(reason)
    end)
  end

  defp repo_pool_size(repo) do
    repo.config()
    |> Keyword.get(:exograph_bulk_concurrency, 2)
    |> min(System.schedulers_online())
    |> max(1)
  end

  @doc false
  def execute!(repo, sql, params) do
    Ecto.Adapters.SQL.query!(repo, sql, params)
    :ok
  end

  @doc false
  def query(repo, sql, params \\ []), do: Ecto.Adapters.SQL.query(repo, sql, params)
end
