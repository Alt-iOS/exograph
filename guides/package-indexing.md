# Package Indexing

## Indexing Hex.pm

`mix exograph.index.hex` is the primary way to index Hex packages. It downloads
tarballs, extracts them to a temp directory, indexes them, and cleans up.

    mix exograph.index.hex --mode latest --concurrency 8 --prefix hex

For a live dashboard during the run:

    mix exograph.index.hex --mode latest --concurrency 8 --web --port 4200

Open `http://localhost:4200/progress` to watch per-package status, rate, and ETA.

### Scale

On a full Hex.pm run with `--mode latest`:

| Metric | Value |
|--------|-------|
| Packages indexed | ~21k |
| Fragments | 13.8M |
| References | 35M |
| Database size | ~34 GB |
| Time (8 workers) | ~28 minutes |

### Modes

| Mode | Description |
|------|-------------|
| `latest` | Most recent version of each package |
| `top --limit N` | Top N most-downloaded packages |
| `all` | Every published version |

### Streaming pipeline

Each package follows: download tarball → extract to tmpdir → index → cleanup.

Peak disk usage is `concurrency × (largest package tarball)` — typically a few
hundred MB regardless of total corpus size. Non-Elixir packages (no `.ex` files)
are detected before disk write and skipped.

### Resume behavior

Already-indexed packages (matched by name+version) are skipped automatically.
Use `--force` to re-index everything.

### Mirror balancing

Multiple `--mirror` flags distribute downloads round-robin:

    mix exograph.index.hex \
      --mirror https://repo.hex.pm \
      --mirror https://repo.hex.pm/mirror \
      --concurrency 16

### Caching tarballs

Pass `--cache-tarballs DIR` to keep downloaded tarballs on disk. On subsequent
runs, already-cached tarballs are not re-downloaded.

    mix exograph.index.hex --cache-tarballs /data/hex-cache --mode latest

## Manual directory-based indexing

For non-Hex source archives or local package checkouts, use `Exograph.index/2`
directly:

```elixir
Exograph.index("sources/req_llm-1.11.0",
  repo: MyApp.Repo,
  migrate?: true,
  package_version: [
    ecosystem: :hex,
    name: "req_llm",
    version: "1.11.0",
    source_ref: "hex:req_llm:1.11.0"
  ]
)
```

Index multiple versions into the same prefix:

```elixir
for version <- ["1.11.0", "1.12.0"] do
  Exograph.index("sources/req_llm-#{version}",
    repo: MyApp.Repo,
    package_version: [ecosystem: :hex, name: "req_llm", version: version]
  )
end
```

Package and package-version records are normalized separately from files and
fragments, so re-indexing the same version is idempotent.

## Scoped queries

Restrict search to a specific package or version:

```elixir
Exograph.search(index, "Repo.get!(_, _)",
  package_id: pkg_id
)
```

The DSL and code-fact search APIs accept the same scope fields. The web UI shows
a package selector to scope the search without code changes.

## See also

- [Mix Tasks](mix-tasks.md) — full `mix exograph.index.hex` option reference
- [Web UI](web-ui.md) — progress dashboard
- [Postgres and ParadeDB](postgres-paradedb.md) — performance tuning for large indexes
