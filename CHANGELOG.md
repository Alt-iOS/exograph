# Changelog

## 0.2.0

- Populate `fragment.module` with containing module name (97% coverage)
- Drop redundant `symbols` jsonb, `abstract_hash`, `mfa_*` columns
- Filter operator/structural noise from references (26% fewer rows)
- Use SHA-256 for content hash (32B vs 64B)
- Add `examples/index_hex_corpus.exs`

### Breaking

Schema changes require a fresh index. Drop existing tables and re-migrate.

## 0.1.0

Initial public release.

- Postgres-backed indexing for Elixir source code with integer primary keys and normalized terms
- ExAST-verified structural search with GIN term index acceleration
- Streaming batched fragment verification with early termination
- Normalized Ecto schemas for files, fragments, comments, definitions, references, packages, versions
- Optional Reach call graph extraction (graph nodes and call edges)
- Ecto-shaped DSL with fragment/definition/reference/call-edge sources
- Fragment joins with definitions, references, and call edges
- Multi-join fragment queries (up to 3 joins)
- Containing-function join semantics via precomputed `end_line`
- Fact-first join execution for selective predicates
- DSL plan validation (bindings, associations, structural predicates)
- Package/version-scoped indexing and queries
- Optional ParadeDB BM25 text/code-fact retrieval
- ExDNA structural similarity search
- Mix tasks for indexing and searching
- Tested against 2000 Hex packages (1.8M fragments, 5.5M references, 1M call edges)
