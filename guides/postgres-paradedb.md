# Postgres and ParadeDB

Postgres is Exograph's built-in backend. Exograph uses Ecto migrations, schemas,
`Repo` operations, and transactions for source files, fragments, comments,
definitions, references, package metadata, and call graph facts.

ParadeDB's `pg_search` extension is optional and accelerates BM25 text/code-fact
retrieval when available.

## Indexing with Postgres

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.Repo,
    migrate?: true,
    bm25?: true
  )
```

`backend: :postgres` is accepted explicitly, but Postgres is the only built-in
backend.

## Tables

The canonical migration creates normalized Ecto-backed tables including:

- `exograph_packages`
- `exograph_package_versions`
- `exograph_files`
- `exograph_fragments`
- `exograph_comments`
- `exograph_definitions`
- `exograph_references`
- `exograph_graph_nodes`
- `exograph_call_edges`
- `exograph_tree_nodes`

Fragments store package, package version, and file IDs. Source text is stored
once in `exograph_files`.

## ParadeDB / `pg_search`

When ParadeDB's `pg_search` extension is available, `migrate?: true` can create
BM25 indexes over source files, comments, definitions, and references. Source
files use ParadeDB's `pdb.source_code` tokenizer; symbol names use tokenizers
such as `pdb.ngram` for prefix/partial matching.

Raw SQL is limited to areas Ecto cannot express directly:

- `CREATE EXTENSION`
- ParadeDB `USING bm25`
- ParadeDB tokenizer casts such as `source::pdb.source_code`
- ParadeDB operators such as `|||` and `&&&`
- ParadeDB scoring such as `pdb.score(...)`

## Recommended Postgres settings

Default Postgres settings are conservative. For large indexes (10M+ fragments),
tuning makes a significant difference — benchmarks show 2–37× faster queries.

```sql
-- More parallel workers for ParadeDB BM25 scans
ALTER SYSTEM SET max_parallel_workers_per_gather = 4;
ALTER SYSTEM SET max_parallel_workers = 16;
ALTER SYSTEM SET max_worker_processes = 24;

-- Memory: adjust to your available RAM
ALTER SYSTEM SET shared_buffers = '4GB';           -- ~25% of RAM
ALTER SYSTEM SET effective_cache_size = '12GB';     -- ~75% of RAM
ALTER SYSTEM SET work_mem = '256MB';                -- per-operation sort/hash
ALTER SYSTEM SET maintenance_work_mem = '1GB';      -- for CREATE INDEX / VACUUM

SELECT pg_reload_conf();  -- applies all except shared_buffers
-- shared_buffers requires a Postgres restart
```

After restarting, prewarm the BM25 indexes into the buffer cache:

```sql
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
SELECT pg_prewarm('myprefix_files_bm25_idx');
SELECT pg_prewarm('myprefix_fragments_bm25_idx');
SELECT pg_prewarm('myprefix_definitions_bm25_idx');
```

For write-heavy indexing runs, increase parallelism for index creation:

```sql
SET max_parallel_maintenance_workers = 8;
SET maintenance_work_mem = '2GB';
```

## Fallback behavior

Exograph remains usable without ParadeDB. Text/code-fact search falls back to
Postgres ILIKE (accelerated by `pg_trgm` GIN indexes) and `~*` for regex.

## CLI examples

```bash
mix exograph.index --backend postgres --repo MyApp.Repo --migrate lib test
mix exograph.search 'Repo.get!(_, _)' --backend postgres --repo MyApp.Repo --migrate lib
mix exograph.search 'running shoes' --text --backend postgres --repo MyApp.Repo --migrate lib
```

## Testing

The test suite validates real indexing, structural search, selector search,
text search, tree-node lookup, code-fact lookup, similarity search, and DSL
queries against Postgres.

```bash
EXOGRAPH_DATABASE_URL=postgres://postgres:postgres@localhost:5432/exograph_test \
  mix test
```
