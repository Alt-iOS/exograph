# Getting Started

Exograph is a local/self-hosted code intelligence index for Elixir. You point it
at source code and an Ecto repo; it extracts structural fragments and code facts,
stores them in Postgres, and exposes search/query APIs over the index.

## Installation

Exograph is early-stage and currently installed from GitHub:

```elixir
def deps do
  [
    {:exograph, github: "elixir-vibe/exograph"}
  ]
end
```

Exograph uses Postgres as its built-in backend. ParadeDB's `pg_search` extension
is optional.

## Repo setup

Use an existing Ecto repo or create a dedicated one for code intelligence data.
The repo must be started before indexing.

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.Repo,
    migrate?: true
  )
```

`migrate?: true` creates the Exograph tables under the configured prefix. Use a
dedicated prefix if you want to keep Exograph data separate from application
data:

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.Repo,
    prefix: "exograph",
    migrate?: true
  )
```

## First structural search

```elixir
{:ok, hits} = Exograph.search(index, "Repo.get!(_, _)")
```

Patterns are ExAST patterns. Postgres retrieves candidate fragments and ExAST
verifies the final structural match.

## First DSL query

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

The DSL combines relational code facts with structural ExAST verification.

## Optional Reach extraction

Reach extraction is enabled by default when the optional `:reach` dependency is
available. Disable it when you only want ExAST facts:

```elixir
Exograph.index("lib",
  repo: MyApp.Repo,
  migrate?: true,
  extractors: [:ex_ast]
)
```

## Local test database

The test suite uses a real Postgres database. Set `EXOGRAPH_DATABASE_URL` when
the default local database is not available:

```bash
EXOGRAPH_DATABASE_URL=postgres://postgres:postgres@localhost:5432/exograph_test \
  mix test
```
