# Postgres and ParadeDB

Postgres is Exograph's alternative Ecto backend. Exograph uses Ecto migrations, schemas,
`Repo` operations, and transactions for source files, fragments, comments,
definitions, references, package metadata, and call graph facts.

ParadeDB's `pg_search` extension is optional and accelerates BM25 text/code-fact
retrieval when available.

## Indexing with Postgres

```elixir
{:ok, index} =
  Exograph.index("lib",
    backend: :postgres,
    repo: MyApp.Repo,
    migrate?: true,
    bm25?: true
  )
```

DuckDB/QuackDB is the default backend, so pass `backend: :postgres` explicitly for Postgres indexes.

## Tables

The canonical migration creates normalized Ecto-backed tables under the configured
prefix (default: `exograph`):

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

Source text is stored once in `exograph_files`. Fragments carry package, version,
and file foreign keys.

## Indexes

### Structural search — `(kind, name, arity)` btree

A btree index on `(kind, name, arity)` on the fragments table lets structural
queries that know the kind or name skip the GIN term index entirely and go
straight to a btree range scan. This is the hot path for patterns like
`def handle_call(_, _, _) do ... end` where kind=`def` and name=`handle_call`
are extracted at query planning time.

### Term index — GIN

The inverted index on fragment terms (`exograph_terms`) uses a GIN index. Terms
are extracted by ExAST at indexing time and stored as normalized strings.
Candidate retrieval scans the GIN index; ExAST verification follows.

### Text search — `pg_trgm` GIN

`pg_trgm` GIN indexes on `files.source` and `files.comments_text` enable fast
`ILIKE` and `~*` regex without a full table scan:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX CONCURRENTLY ON exograph_files USING gin (source gin_trgm_ops);
CREATE INDEX CONCURRENTLY ON exograph_files USING gin (comments_text gin_trgm_ops);
```

Migrations create these automatically. Without `pg_trgm`, text/regex search
falls back to sequential scans.

## ParadeDB / `pg_search`

When ParadeDB's `pg_search` extension is installed, `migrate?: true` creates BM25
indexes over source files, comments, definitions, and references. Source files use
ParadeDB's `pdb.source_code` tokenizer; symbol names use `pdb.ngram` for
prefix/partial matching.

Raw SQL is limited to areas Ecto cannot express directly:

- `CREATE EXTENSION`
- ParadeDB `USING bm25`
- ParadeDB tokenizer casts such as `source::pdb.source_code`
- ParadeDB operators (`|||`, `&&&`)
- ParadeDB scoring (`pdb.score(...)`)

## Recommended Postgres settings

Default Postgres settings are conservative. For future bulk-ingest work, see
[Postgres COPY staging](postgres-copy-staging.md). On a 13.8M fragment index, these
settings reduce structural search time from ~600ms to ~78ms and enable parallel
BM25 scans.

```sql
-- Parallel workers for ParadeDB BM25 scans
ALTER SYSTEM SET max_parallel_workers_per_gather = 4;
ALTER SYSTEM SET max_parallel_workers = 16;
ALTER SYSTEM SET max_worker_processes = 24;

-- Memory — adjust to available RAM
ALTER SYSTEM SET shared_buffers = '4GB';           -- ~25% of RAM
ALTER SYSTEM SET effective_cache_size = '12GB';     -- ~75% of RAM
ALTER SYSTEM SET work_mem = '256MB';                -- per-operation sort/hash
ALTER SYSTEM SET maintenance_work_mem = '1GB';      -- for CREATE INDEX / VACUUM

SELECT pg_reload_conf();
-- shared_buffers requires a Postgres restart
```

After restarting, prewarm BM25 indexes into the buffer cache:

```sql
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
SELECT pg_prewarm('hex_files_bm25_idx');
SELECT pg_prewarm('hex_fragments_bm25_idx');
SELECT pg_prewarm('hex_definitions_bm25_idx');
```

For write-heavy indexing runs, increase parallelism for index creation:

```sql
SET max_parallel_maintenance_workers = 8;
SET maintenance_work_mem = '2GB';
```

## Fallback behavior

Without ParadeDB, text/regex search uses Postgres `ILIKE` (accelerated by
`pg_trgm` GIN indexes) and `~*`. Without `pg_trgm`, text search falls back to a
sequential scan — usable for small indexes but slow at scale.

## Testing

```bash
EXOGRAPH_DATABASE_URL=postgres://postgres:postgres@localhost:5432/exograph_test \
  mix test
```
