# Getting Started

## Installation

Add Exograph to your deps:

```elixir
def deps do
  [
    {:exograph, "~> 0.6"}
  ]
end
```

**Postgres is required.** ParadeDB's `pg_search` extension is optional — without
it, text search falls back to `pg_trgm` ILIKE, which is fast but not BM25-ranked.

Install `pg_trgm` if it is not already enabled:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

## Index your project

Point Exograph at your source directories with `--migrate` to create the tables:

    mix exograph.index --repo MyApp.Repo --migrate lib

To also index tests and set a custom prefix:

    mix exograph.index --repo MyApp.Repo --migrate --prefix exograph lib test

From Elixir:

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.Repo,
    prefix: "exograph",
    migrate?: true
  )
```

`migrate?: true` runs Exograph's Ecto migrations under the configured prefix.
Re-running is safe; migrations are idempotent.

## Search from CLI

Structural search — finds fragments matching an ExAST pattern:

    mix exograph.search 'Repo.get!(_, _)' --repo MyApp.Repo --migrate lib

Text search:

    mix exograph.search 'TODO' --text --repo MyApp.Repo --migrate lib

Regex search:

    mix exograph.search 'Repo\.get!\(' --regex --repo MyApp.Repo --migrate lib

Structural search with predicates:

    mix exograph.search 'def _ do ... end' \
      --repo MyApp.Repo --migrate lib \
      --contains 'Repo.transaction(_)' \
      --not-contains 'IO.inspect(_)'

## Start the web UI

    mix exograph.web --prefix exograph --port 4200

Open `http://localhost:4200`. The editor supports structural, text, and regex
modes. Pass `--database-url` or set `EXOGRAPH_DATABASE_URL` when not using an
application repo:

    EXOGRAPH_DATABASE_URL=postgres://localhost/mydb \
      mix exograph.web --prefix exograph --port 4200

## Index Hex.pm packages

Download and index packages straight from Hex.pm:

    mix exograph.index.hex --mode top --limit 1000 --concurrency 8

This streams: download tarball → extract to tmpdir → index → cleanup. Peak disk
usage is proportional to concurrency, not total package count. Already-indexed
packages are skipped automatically.

Watch progress live by adding `--web`:

    mix exograph.index.hex --mode latest --concurrency 8 --web --port 4200

The dashboard at `http://localhost:4200/progress` shows per-package status,
rate, and ETA.

Modes:
- `latest` — most recent version of each package (default)
- `top --limit N` — top N most-downloaded packages
- `all` — every published version

See [Package Indexing](package-indexing.md) for scale numbers and full options.

## Next steps

- [Querying](querying.md) — structural patterns, text/regex search, planning
- [DSL](dsl.md) — join code facts with structural predicates
- [Mix Tasks](mix-tasks.md) — all CLI options
- [Postgres and ParadeDB](postgres-paradedb.md) — performance tuning for large indexes
