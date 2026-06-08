# Postgres COPY staging design

This note records the next credible Postgres bulk-ingest direction for Exograph. The small `--postgres-copy` experiment that copied only `fragment_terms` did not improve indexing because Exograph currently appends many package-sized batches; COPY setup overhead dominated.

A fair COPY implementation should batch across packages and load larger staging tables.

## Goals

- Preserve existing functionality and persisted data: files, fragments, ASTs, hashes, terms, facts, graph nodes, call edges, and package scope.
- Preserve upsert/conflict semantics for package versions, files, fragments, and terms.
- Keep stable IDs available before dependent rows are inserted.
- Keep query indexes deferred until after the load when `--postgres-defer-indexes` is enabled.

## Proposed pipeline

1. Create regular target tables with only required unique indexes/constraints.
2. Create temporary or unlogged staging tables for high-volume rows:
   - files
   - fragments
   - comments
   - definitions
   - references
   - graph nodes
   - call edges
   - terms
   - fragment_terms
3. Accumulate rows across many packages in memory or bounded disk-backed chunks.
4. COPY staging chunks using `COPY ... FROM STDIN`.
5. Merge dimensions first:
   - packages
   - package_versions
   - terms
   - files
   - fragments
6. Fetch generated IDs into hash maps keyed by natural keys:
   - package `(ecosystem, name)`
   - package version `(package_id, version)`
   - file `(package_version_id, sha256)`
   - fragment `content_hash`
   - term text
7. Rewrite dependent staging rows with database IDs.
8. COPY/insert fact tables in dependency order.
9. Build deferred indexes and run `ANALYZE`.

## Candidate implementation shape

Add an opt-in loader module rather than complicating ordinary per-package indexing:

```elixir
Exograph.Postgres.StagingLoader.load_packages(repo, prefix, package_rows, opts)
```

The Hex corpus task can route to it only when all of these are true:

- backend is Postgres
- `postgres_copy?: true`
- package workload is corpus-style, not ad-hoc source indexing
- staging batch size is above a threshold

## Risks

- Memory blow-up if too many package rows are accumulated.
- Duplicate handling must remain identical to current `insert_all` conflict behavior.
- Foreign-key order and ID resolution add complexity.
- Temporary/unlogged staging tables are appropriate for rebuildable local indexes, not durable ingestion guarantees.

## Recommendation

Do not extend the current row-by-row COPY helper further. The next useful implementation should be a dedicated staging loader with large batches and explicit ID-resolution phases. Until then, keep `--postgres-copy` documented as experimental and do not use it for headline benchmark claims.
