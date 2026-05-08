# Postgres and ParadeDB

Postgres is Exograph's built-in backend. Exograph uses Ecto migrations, schemas,
`Repo` operations, and transactions for source files, fragments, comments,
definitions, references, package metadata, and call graph facts.

ParadeDB's `pg_search` extension is optional and accelerates BM25 text/code-fact
retrieval when available.

## Indexing with Postgres

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.Repo,
    migrate?: true,
    bm25?: true
  )
```

`backend: :postgres` is accepted explicitly, but Postgres is the only built-in
backend.

## Tables

The canonical migration creates normalized Ecto-backed tables including:

- `exograph_packages`
- `exograph_package_versions`
- `exograph_files`
- `exograph_fragments`
- `exograph_comments`
- `exograph_definitions`
- `exograph_references`
- `exograph_graph_nodes`
- `exograph_call_edges`
- `exograph_tree_nodes`

Fragments store package, package version, and file IDs. Source text is stored
once in `exograph_files`.

## ParadeDB / `pg_search`

When ParadeDB's `pg_search` extension is available, `migrate?: true` can create
BM25 indexes over source files, comments, definitions, and references. Source
files use ParadeDB's `pdb.source_code` tokenizer; symbol names use tokenizers
such as `pdb.ngram` for prefix/partial matching.

Raw SQL is limited to areas Ecto cannot express directly:

- `CREATE EXTENSION`
- ParadeDB `USING bm25`
- ParadeDB tokenizer casts such as `source::pdb.source_code`
- ParadeDB operators such as `|||` and `&&&`
- ParadeDB scoring such as `pdb.score(...)`

## Fallback behavior

Exograph remains usable without ParadeDB. Text/code-fact search falls back to
Postgres-backed candidate retrieval plus verification where applicable.

## CLI examples

```bash
mix exograph.index --backend postgres --repo MyApp.Repo --migrate lib test
mix exograph.search 'Repo.get!(_, _)' --backend postgres --repo MyApp.Repo --migrate lib
mix exograph.search 'running shoes' --text --backend postgres --repo MyApp.Repo --migrate lib
```

## Testing

The test suite validates real indexing, structural search, selector search,
text search, tree-node lookup, code-fact lookup, similarity search, and DSL
queries against Postgres.

```bash
EXOGRAPH_DATABASE_URL=postgres://postgres:postgres@localhost:5432/exograph_test \
  mix test
```
