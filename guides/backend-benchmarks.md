# Backend benchmarks

These are local Exograph backend benchmarks for the Hex.pm `top` workload. They are intended to compare Exograph's current backend implementations on this machine, not to make a universal claim about PostgreSQL or DuckDB.

## Method

All runs used the same package cache and full Exograph persistence: files, fragments, ASTs, hashes, symbols, references, terms, and queryable facts were retained.

Common settings:

```bash
--mode top
--runs 3
--concurrency 4
--index-concurrency 4
--duckdb-threads 1
--postgres-defer-indexes
--postgres-synchronous-commit off
--postgres-maintenance-work-mem 512MB
--postgres-max-parallel-maintenance-workers 2
```

DuckDB sharded runs used:

```bash
--duckdb-shards 4 --duckdb-recovery-mode no_wal_writes
```

Postgres settings are a rebuildable/local-index challenge mode: deferred non-unique query indexes, `synchronous_commit=off`, and larger maintenance memory. They are not durable-production defaults.

## Indexing medians

| Workload | Postgres plain | DuckDB plain | DuckDB sharded plain | Result |
|----------|----------------|--------------|----------------------|--------|
| `top --limit 100` | 38.42s | 39.22s | 41.17s | tuned Postgres slightly faster |
| `top --limit 500` | 181.22s | 109.27s | 91.05s | DuckDB 1.66× faster; sharded DuckDB 1.99× faster |

For `limit 100`, the systems are close and tuned Postgres wins indexing. For `limit 500`, DuckDB wins indexing, and sharding improves throughput further.

## Query medians

### `top --limit 100`

| Query | Postgres plain | DuckDB plain | DuckDB sharded plain |
|-------|----------------|--------------|----------------------|
| `api_text_defmodule` | 71.1ms | 27.7ms | 45.4ms |
| `references_enum` | 24.1ms | 2.3ms | 3.3ms |
| `files_defmodule` | 31.0ms | 7.3ms | 2.4ms |
| `api_comments_todo` | 134.3ms | 129.8ms | 65.6ms |

### `top --limit 500`

| Query | Postgres plain | DuckDB plain | DuckDB sharded plain |
|-------|----------------|--------------|----------------------|
| `api_text_defmodule` | 134.2ms | 49.0ms | 37.0ms |
| `references_enum` | 56.7ms | 8.9ms | 9.9ms |
| `files_defmodule` | 98.3ms | 23.6ms | 7.1ms |
| `api_comments_todo` | 143.3ms | 159.1ms | 199.9ms |

Search/query paths usually favor DuckDB materially, especially on the larger workload.

## Artifacts

Machine-readable benchmark artifacts are generated locally and intentionally not committed to git. Use `--output-json` for the JSON report and `--explain-dir` for Postgres plans, for example:

```bash
mix exograph.bench.backends \
  --mode top --limit 500 --runs 3 \
  --only postgres_plain,duckdb_plain,duckdb_sharded_plain \
  --output-json bench-results/backend-limit500-runs3-current.json \
  --explain-dir bench-results/explain-limit500-runs3-current
```

`bench-results/` is gitignored to avoid polluting the repository with local benchmark outputs. The tables above record the latest checked benchmark summary; regenerate artifacts locally when you need machine-readable evidence or plans.

## Current fair wording

A defensible summary is:

> On Exograph's Hex.pm top-package workload, tuned Postgres is slightly faster at indexing 100 packages. At 500 packages, DuckDB indexes about 1.66× faster single-node and about 1.99× faster with 4 shards, while several important query paths are roughly 3×–14× faster on DuckDB. These numbers describe Exograph's current backends and local benchmark setup, not PostgreSQL or DuckDB universally.
