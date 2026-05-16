# Exograph

Local CodeQL-style code search for Elixir, backed by Postgres and ExAST.

Exograph indexes Elixir source code into normalized Ecto/Postgres tables: files,
AST fragments, comments, definitions, references, package versions, and optional
Reach call graph facts. You can then query that index with structural AST
patterns, text search, symbol/reference filters, and Ecto-shaped joins.

Exograph was originally built to stress-test Reach and ExAST on larger
real-world codebases and Hex package sets. It is now a reusable local/self-hosted
code intelligence layer for Elixir tooling.

## What is Exograph?

Exograph is:

- a library for indexing Elixir source code into Postgres
- a set of Ecto schemas and migrations for normalized code facts
- a structural search engine using ExAST for exact AST verification
- an optional Reach-backed call graph index
- a foundation for CodeQL-like Elixir queries over one project or many package versions

Exograph is not currently:

- a hosted search service
- a language server
- a general multi-language analyzer
- a replacement for ExAST or Reach

## Why?

Use Exograph when text search is not enough:

- find functions matching an AST shape
- search definitions and references across packages
- ask “which private functions call `Repo.transaction/1`?”
- index multiple Hex package versions into one database
- combine relational filters with exact ExAST verification
- persist Reach call graph facts for caller/callee queries

## Installation

```elixir
def deps do
  [
    {:exograph, "~> 0.4"}
  ]
end
```

Exograph currently requires Postgres. ParadeDB's `pg_search` extension is
optional and enables BM25-backed text/code-fact retrieval.

## Quickstart

Point Exograph at Elixir source and an Ecto repo:

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.Repo,
    migrate?: true
  )

{:ok, hits} = Exograph.search(index, "Repo.get!(_, _)")
```

Exograph uses Postgres for candidate retrieval and ExAST for exact structural
verification.

## Web UI

Exograph includes an embedded web interface for exploring indexes:

    mix exograph.web --prefix myindex --port 4200

Features:
- Monaco editor with Elixir syntax highlighting and autocompletion
- Structural and full-text search modes
- IDE-style error diagnostics
- Collapsible results grouped by package with code previews
- Hex.pm links on package names

## JSON API

The web server also exposes a JSON API:

    POST /api/search   — structural or text search
    POST /api/query    — DSL query execution
    GET  /api/packages — list indexed packages
    GET  /api/stats    — index statistics

Cursor pagination via `cursor`/`next_cursor`. Rate limited (60 req/min).

## Query with code facts

Use `Exograph.DSL` when you want to combine structural AST patterns with indexed
facts such as references or call edges:

```elixir
import Exograph.DSL

query =
  from(f in Fragment,
    join: r in assoc(f, :references),
    where: r.qualified_name == "Repo.transaction/1",
    where: matches(f, "def _ do ... end")
  )

{:ok, hits} = Exograph.all(index, query)
```

Reach call graph facts can also be queried directly:

```elixir
Exograph.search_callers(index, "Repo.transaction/1")
Exograph.search_callees(index, "MyApp.Accounts.update_user/2")
```

## How it compares

| Tool | Scope | Storage | Query style | Elixir AST-aware? | Best for |
|------|-------|---------|-------------|-------------------|----------|
| `ripgrep` | local text search | none | regex/text | no | fast ad-hoc text search |
| ExAST | structural AST matching | none/advisory terms | AST patterns/selectors | yes | exact search and patching |
| Reach | dependence analysis | in-memory graph/reports | APIs / Mix tasks | yes | call/data/control-flow analysis |
| CodeQL | semantic code analysis | CodeQL database | QL language | not first-class Elixir | security analysis at scale |
| Sourcegraph | cross-repo search | external index | text/structural depending setup | not Elixir-specific | organization-wide search |
| Exograph | Elixir code fact index | Postgres/ParadeDB | ExAST + Ecto-shaped DSL | yes | local/self-hosted Elixir code intelligence |

## Features

- ExAST-backed structural search with exact verification
- normalized Ecto/Postgres storage for files, fragments, comments, definitions, references, packages, versions, and call edges
- package/version-scoped indexes for Hex or other source archives
- optional Reach call graph extraction
- optional ParadeDB BM25 text/fact retrieval
- ExDNA-powered structural similarity
- Mix tasks for indexing and searching

## Documentation

| Guide | Content |
|-------|---------|
| [Getting Started](guides/getting-started.md) | Installation, Postgres setup, first index/search |
| [Querying](guides/querying.md) | Structural search, ExAST selectors, planning/explain |
| [DSL](guides/dsl.md) | `Exograph.DSL`, joins, selects, predicates |
| [Code Facts](guides/code-facts.md) | Definitions, references, comments, text search, typed hits |
| [Call Graph](guides/call-graph.md) | Reach extraction, callers/callees, call edge DSL |
| [Postgres and ParadeDB](guides/postgres-paradedb.md) | Storage backend, migrations, BM25 |
| [Package Indexing](guides/package-indexing.md) | Indexing many package versions into one database |
| [Mix Tasks](guides/mix-tasks.md) | CLI indexing and searching |
| [Comparisons](guides/comparisons.md) | Exograph vs ExAST, Reach, CodeQL, Sourcegraph |
| [Architecture](guides/architecture.md) | Storage model, verifier contract, extraction pipeline |

## Status

Exograph is early-stage. The current focus is a reliable Postgres-backed index
and query layer for Elixir-specific code intelligence.

The core design is stable:

- ExAST remains the semantic authority for structural matches
- Reach is an optional semantic extractor
- Postgres is the built-in production backend
- ParadeDB is optional acceleration for text/code-fact search

## License

MIT.
