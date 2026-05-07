# Architecture

Exograph is built around one principle: storage and indexes are advisory;
ExAST remains the semantic authority for structural matches.

## Components

- ExAST extracts structural terms, comments, symbols, and verifies patterns
- ExDNA provides structural fingerprints for fragments and similarity search
- Reach optionally extracts call graph facts
- Ecto/Postgres stores normalized files, fragments, facts, package scope, and graph facts
- ParadeDB optionally accelerates text and code-fact retrieval

## Indexing pipeline

Indexing roughly follows this flow:

```txt
source files
  ├── ExAST extractor
  │   ├── fragments
  │   ├── comments
  │   ├── definitions
  │   └── references
  ├── Reach extractor (optional)
  │   ├── graph nodes
  │   └── call edges
  └── Postgres stores
      ├── files
      ├── fragments
      ├── facts
      └── package/version scope
```

## Storage model

`Exograph.Index` separates execution by concern:

- Postgres inverted index: structural term candidate retrieval from fragment rows
- fragment store: AST blobs, ExDNA hashes, symbols, and file joins
- source files: source text and aggregated comment text stored once per file
- code facts: normalized comments, definitions, references, graph nodes, and call edges
- tree access: derived lazily from stored AST fragments
- verifier: `ExAST.Pattern` / `ExAST.Query`
- similarity: ExDNA structural reranking

## Query execution

Structural queries are planned into candidate retrieval plus verification:

```txt
ExAST selector
  ├── required/advisory terms
  ├── Postgres candidate scan
  ├── hydrate fragments/source
  └── ExAST verification
```

DSL queries add relational candidate filters before structural verification:

```txt
Exograph.DSL.Query
  ├── Exograph.DSL.Plan validation
  ├── Ecto query over fragments/facts/calls
  ├── containing-function join semantics
  └── ExAST verification for fragment matches
```

## Why Postgres

Postgres gives Exograph:

- durable local/self-hosted indexes
- Ecto schemas and migrations
- package/version scope
- joins across structural and semantic facts
- optional ParadeDB BM25 indexes
- a natural substrate for tools that already run inside Elixir applications

## Raw SQL boundary

Exograph uses Ecto where possible. Raw SQL is limited to extension/backend
features Ecto cannot express directly, especially ParadeDB index creation,
tokenizer casts, BM25 operators, and scoring.
