# Mix Tasks

Exograph includes Mix tasks for indexing and searching from the command line.

## Indexing

Index the current project:

```bash
mix exograph.index --repo MyApp.Repo --migrate lib test
```

Useful options:

```bash
mix exograph.index --repo MyApp.Repo --migrate lib test --stats
mix exograph.index --repo MyApp.Repo --migrate --no-bm25 lib
mix exograph.index --repo MyApp.Repo --migrate --json lib
```

## Searching

Structural search:

```bash
mix exograph.search 'Repo.get!(_, _)' --repo MyApp.Repo --migrate lib
```

Structural search with relationship filters:

```bash
mix exograph.search 'def _ do ... end' \
  --repo MyApp.Repo \
  --migrate lib \
  --contains 'Repo.transaction(_)'

mix exograph.search 'def _ do ... end' \
  --repo MyApp.Repo \
  --migrate lib \
  --contains 'Repo.transaction(_)' \
  --not-contains 'IO.inspect(_)'
```

Explain a query:

```bash
mix exograph.search 'Repo.get!(_, _)' --repo MyApp.Repo --migrate lib --explain
```

Text and regex search:

```bash
mix exograph.search '/users/:id' --repo MyApp.Repo --migrate lib --text
mix exograph.search 'Repo\.get!\(' --repo MyApp.Repo --migrate lib --regex
```

## Backend flags

Postgres is the only built-in backend, but `--backend postgres` is accepted:

```bash
mix exograph.index --backend postgres --repo MyApp.Repo --migrate lib test
mix exograph.search 'Repo.get!(_, _)' --backend postgres --repo MyApp.Repo --migrate lib
```

## Web UI

    mix exograph.web --prefix exograph --port 4200

Starts a standalone web interface for exploring an index. See the [Web UI guide](web-ui.md) for details.
