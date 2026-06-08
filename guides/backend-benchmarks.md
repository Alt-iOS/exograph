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
| `top --limit 500` | 145.25s | 107.36s | 85.55s | DuckDB 1.35× faster; sharded DuckDB 1.70× faster |

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
| `api_text_defmodule` | 243.6ms | 47.1ms | 38.6ms |
| `references_enum` | 48.1ms | 7.7ms | 9.9ms |
| `files_defmodule` | 98.0ms | 23.4ms | 7.2ms |

Search/query paths usually favor DuckDB materially, especially on the larger workload.

## Artifacts

Machine-readable benchmark artifacts live under `bench-results/`:

- `backend-limit100-runs3-stable.json`
- `backend-limit500-runs3-postgres-512mb-clean.json`
- `backend-limit500-runs3-defer.json`

The `limit 500` Postgres artifact is from a clean Postgres-only rerun after removing local service contention. DuckDB medians use the existing repeated DuckDB runs from `backend-limit500-runs3-defer.json`.

## Current fair wording

A defensible summary is:

> On Exograph's Hex.pm top-package workload, tuned Postgres is slightly faster at indexing 100 packages. At 500 packages, DuckDB indexes about 1.35× faster single-node and about 1.70× faster with 4 shards, while several important query paths are roughly 4×–13× faster on DuckDB. These numbers describe Exograph's current backends and local benchmark setup, not PostgreSQL or DuckDB universally.
