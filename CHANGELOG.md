# Changelog

## 0.4.1

- Upgraded Volt to 0.11.1, removed `oxc` override
- `module_types` configured in `config :volt` instead of hardcoded
- Asset builds use `mix volt.build` instead of internal Volt APIs
- Extracted `Exograph.Web.Monaco` for Monaco Editor bundling

## 0.4.0

### Web UI

- Monaco editor with built-in Elixir syntax highlighting, auto-closing brackets, indentation
- Elixir intellisense via `Code.Fragment.cursor_context` — completes DSL macros, modules, fields
- IDE-style error diagnostics with red squiggly underlines and hover messages
- Format button via `Code.format_string!`
- Example query cards with descriptions
- Collapsible package groups, loading spinner, sticky editor
- URL query params (`?q=`) for shareable links
- Hex.pm links on package names
- Load more pagination
- Thin scrollbar via Tailwind v4.3 `scrollbar-thin`
- `phoenix_iconify` for icons

### API

- Cursor-based pagination (`cursor` param, `next_cursor` in response)
- Rate limiting via Hammer (`x-ratelimit-limit`, `x-ratelimit-remaining` headers, 429 on excess)

### Query engine

- DSL `limit:` clause parsed and respected
- Kind filtering — `def` patterns only match `def` fragments, not modules/expressions
- Keyset pagination replaces OFFSET in internal streaming (O(1) per page)
- Preview shows correct absolute line numbers

### Security

- Replaced `Code.eval_string` with safe AST interpreter (`SafeEval`)
- Dune sandbox for evaluating value expressions in predicates
- Dangerous code (`System.cmd`, `File.read!`, etc.) rejected at parse time

### Code quality

- Zero `any` in TypeScript — proper interfaces for Monaco, LiveView hooks
- `mix volt.js.check` (lint + format) added to CI
- Playwright feature tests for web UI (5 tests)
- API integration tests with Req (10 tests)
- Total: 50 unit + 15 feature = 65 tests

## 0.3.0

- Web UI with Monaco editor, syntax-highlighted search results, and autocompletion (`mix exograph.web`)
- JSON API: `POST /api/search`, `POST /api/query`, `GET /api/packages`, `GET /api/stats`
- Consolidated `Exograph.Postgres.*` namespace (FragmentStore, InvertedIndex, TreeStore)
- Renamed Query → StructuralQuery to disambiguate from DSL.Query
- Split DSL executor into focused modules (Predicates, Scope)
- Removed dead code: legacy Planner subtree, unused Indexer delegator
- Removed single-implementation behaviour modules (Extractor, FragmentStore, InvertedIndex, TreeStore)
- Simplified `Index` struct from 6 fields to 3

### Breaking

Module renames — update any direct references:
- `Exograph.FragmentStore.Postgres` → `Exograph.Postgres.FragmentStore`
- `Exograph.InvertedIndex.Postgres` → `Exograph.Postgres.InvertedIndex`
- `Exograph.TreeStore.Postgres` → `Exograph.Postgres.TreeStore`
- Query → StructuralQuery
- CodeFactQuery → `Exograph.Postgres.FactQuery`

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
