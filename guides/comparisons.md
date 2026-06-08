# Comparisons

Exograph overlaps with text search, structural search, dependence analysis, and
semantic code analysis tools. The key difference is that Exograph is an
Elixir-specific, Postgres-backed code fact index that uses ExAST as its final
structural verifier — and can index all of Hex.pm in under 30 minutes.

## Overview

| Tool | Scope | Storage | Query style | Elixir AST-aware? | Best for |
|------|-------|---------|-------------|-------------------|----------|
| `ripgrep` | local text search | none | regex/text | no | fast ad-hoc text search |
| ExAST | structural AST matching | none/advisory terms | AST patterns/selectors | yes | exact search and patching |
| Reach | dependence analysis | in-memory graph/reports | APIs / Mix tasks | yes | call/data/control-flow analysis |
| CodeQL | semantic code analysis | CodeQL database | QL language | not first-class Elixir | security analysis at scale |
| Sourcegraph | cross-repo search | external index | text/structural depending setup | not Elixir-specific | organization-wide search |
| Exograph | Elixir code fact index | DuckDB/QuackDB or Postgres/ParadeDB | ExAST + Ecto-shaped DSL | yes | local/self-hosted Elixir code intelligence; large Hex package indexing |

## Exograph vs ExAST

| Question | ExAST | Exograph |
|----------|-------|----------|
| What is indexed? | Nothing by default; exposes advisory terms | Files, fragments, comments, symbols, references, calls |
| Storage | Source/in-memory | DuckDB/QuackDB or Postgres |
| Matching authority | ExAST | ExAST |
| Best for | exact AST search, replace, patching, selector semantics | persisted/cross-package code intelligence |
| Scale | scan source or caller-managed index terms | query persisted candidates, then verify with ExAST |

Exograph depends on ExAST. It does not replace it.

## Exograph vs Reach

| Question | Reach | Exograph |
|----------|-------|----------|
| Primary model | dependence graph | normalized code fact index |
| Output | maps, checks, reports, graph queries | persisted rows and query hits |
| Storage | analysis-time graph | DuckDB/QuackDB or Postgres |
| Role | semantic extractor/analyzer | storage/query layer |
| Relationship | provides call graph facts | persists and queries Reach facts |

Exograph started as infrastructure to run Reach and ExAST against larger
codebases and package sets.

## Exograph vs CodeQL

| Question | CodeQL | Exograph |
|----------|--------|----------|
| Languages | many | Elixir-focused |
| Query language | QL | Elixir API / Ecto-shaped DSL / ExAST selectors |
| Database | CodeQL database | DuckDB/QuackDB or Postgres |
| Semantic model | CodeQL libraries | ExAST + Reach + normalized facts |
| Deployment | CodeQL CLI / GitHub Advanced Security | local/self-hosted Elixir library |
| Scale | organization-wide | indexed 21k Hex packages, 13.8M fragments, 28 min |

Exograph is CodeQL-style in the sense that it indexes code facts and lets you ask
semantic questions over them. It is not a CodeQL-compatible database or QL runtime.

## Exograph vs Sourcegraph

Sourcegraph is an organization-wide code search product. Exograph is a library
and schema for Elixir-specific code intelligence. Exograph is useful when you
want local/self-hosted indexed facts and AST-verified Elixir queries rather than
a general cross-language search UI.

## Scale reference

A full `mix exograph.index.hex --mode latest --concurrency 8` run:

| Metric | Value |
|--------|-------|
| Packages | ~21k |
| Fragments | 13.8M |
| References | 35M |
| Database size | ~34 GB |
| Time | ~28 minutes |
| Query time (structural, tuned Postgres) | ~78ms |
