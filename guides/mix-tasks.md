# Mix Tasks

## mix exograph.index

Index Elixir source files into DuckDB or Postgres.

    mix exograph.index --repo MyApp.Repo --migrate lib
    mix exograph.index --repo MyApp.Repo --migrate lib test
    mix exograph.index --repo MyApp.Repo --prefix myindex --migrate --stats lib

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | Ecto repo module |
| `--prefix` | `exograph` | Table prefix |
| `--migrate` | false | Run migrations before indexing |
| `--no-bm25` | false | Skip ParadeDB BM25 index creation |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--stats` | false | Print fragment statistics after indexing |
| `--json` | false | Print summary as JSON |
| `--backend` | `postgres` | `duckdb` or `postgres` |

## mix exograph.search

Structural, text, or regex search from the CLI.

    mix exograph.search 'Repo.get!(_, _)' --repo MyApp.Repo --migrate lib
    mix exograph.search '/users/:id' --text --repo MyApp.Repo lib
    mix exograph.search 'Repo\.get!\(' --regex --repo MyApp.Repo lib

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | Ecto repo module |
| `--prefix` | `exograph` | Table prefix |
| `--migrate` | false | Run migrations before searching |
| `--no-bm25` | false | Skip ParadeDB BM25 index creation |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--limit` / `-n` | `20` | Maximum results |
| `--contains` | — | Require descendant pattern (repeatable) |
| `--not-contains` | — | Reject descendant pattern (repeatable) |
| `--no-verify` | false | Skip ExAST verification |
| `--text` | false | Literal text search |
| `--regex` | false | Regex text search |
| `--json` | false | Print results as JSON |

Structural search with predicates:

    mix exograph.search 'def _ do ... end' \
      --repo MyApp.Repo --migrate lib \
      --contains 'Repo.transaction(_)' \
      --not-contains 'IO.inspect(_)'

## mix exograph.index.hex

Download and index Hex.pm packages in a streaming pipeline.

    mix exograph.index.hex
    mix exograph.index.hex --mode top --limit 5000
    mix exograph.index.hex --backend duckdb --mode latest --duckdb-shards 4 --duckdb-threads 1 --prefix hex
    mix exograph.index.hex --mode latest --web --port 4200

| Option | Default | Description |
|--------|---------|-------------|
| `--mode` | `latest` | `latest`, `top`, or `all` |
| `--limit` | — | Max packages to index |
| `--prefix` | `hex` | Table prefix |
| `--concurrency` | `4` | Parallel download+index workers |
| `--backend` | `postgres` | `duckdb` or `postgres` |
| `--duckdb-shards` | `1` | DuckDB shard count for corpus indexing |
| `--duckdb-threads` | — | DuckDB execution threads per server/shard |
| `--duckdb-recovery-mode` | — | Managed DuckDB recovery mode; use `no_wal_writes` for rebuildable indexes |
| `--manifest-path` | — | Write sharded DuckDB manifest ETF |
| `--shard-dir` | system temp | Directory for managed DuckDB shard files |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--reach` | false | Include Reach call graph extraction |
| `--force` | false | Re-index already-indexed packages |
| `--no-bm25` | false | Skip ParadeDB BM25 index creation |
| `--mirror` | `https://repo.hex.pm` | Tarball mirror URL (repeatable, round-robin) |
| `--cache-tarballs` | — | Directory to cache downloaded tarballs |
| `--database-url` | `EXOGRAPH_DATABASE_URL` | Postgres connection URL |
| `--quackdb-uri` | `QUACKDB_URI` | QuackDB URI for single DuckDB backend |
| `--quackdb-token` | `QUACKDB_TOKEN` | QuackDB token for single DuckDB backend |
| `--repo` | — | Ecto repo module (uses built-in if omitted) |
| `--timeout` | `300` | Per-package timeout in seconds |
| `--web` | false | Start web UI with live progress dashboard |
| `--port` | `4200` | Web UI port (requires `--web`) |

When `--web` is set, the progress dashboard is available at `/progress` during indexing.
The process keeps running after indexing completes so the web UI remains accessible.

Already-indexed packages (by name+version) are skipped unless `--force` is given.
Peak disk usage is proportional to `--concurrency`, not total package count.

## mix exograph.web

Start a standalone web interface for exploring an index.

    mix exograph.web --prefix exograph --port 4200
    mix exograph.web --database-url postgres://localhost/mydb --prefix hex

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | Ecto repo module (uses built-in if omitted) |
| `--prefix` | `exograph` | Table prefix |
| `--port` | `4200` | HTTP port |
| `--database-url` | `EXOGRAPH_DATABASE_URL` | Postgres connection URL |

Requires optional dependencies: `phoenix`, `phoenix_live_view`, `volt`, `bandit`.
See [Web UI](web-ui.md) for editor features, search modes, and API details.
