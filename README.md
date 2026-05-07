# Exograph

Structural search and code intelligence for Elixir.

Exograph combines:

- `ex_ast` patterns and SQL-like queries for exact AST matching
- `ex_dna` fingerprints for structural fragments and near-duplicate search
- normalized Ecto/Postgres storage for packages, files, fragments, comments, definitions, and references
- optional ParadeDB (`pg_search`) BM25 retrieval for source text and code facts
- Reach-derived call graph facts for caller/callee search
- lazy tree access derived from stored AST fragments

## Prototype

```elixir
{:ok, index} =
  Exograph.index("lib/",
    repo: MyApp.Repo,
    migrate?: true,
    bm25?: true,
    min_mass: 8
  )

{:ok, results} = Exograph.search(index, "Repo.get!(_, _)")
```

Relationship-aware queries are supported through `ExAST.Query`:

```elixir
import ExAST.Query

query =
  from("def _ do ... end")
  |> where(contains("Repo.transaction(_)"))
  |> where(not contains("IO.inspect(_)"))

{:ok, results} = Exograph.search(index, query)
```

Selector alternatives, sibling/position predicates, comment predicates, and
capture guards are supported. Index terms stay advisory and ExAST performs exact
verification against the original source when selector features need comments or
source ranges.

```elixir
from(["def _ do ... end", "defp _ do ... end"])
|> where(follows("@doc _"))
|> where(first())

from("left == right")
|> where(^left == ^right)

from("def _ do ... end")
|> where(comment_before(text("transaction wrapper")))
```

## Query planning and explanations

Exograph treats indexes like an RDBMS treats access paths: advisory only. The
logical query remains the source of truth and every physical plan ends in exact
`ExAST` verification unless you explicitly pass `verify: false`. Disjunctions
such as `where(any([...]))` are planned as a union of candidate scans when safe,
then verified exactly.

```elixir
plan = Exograph.plan(index, from("def _ do ... end") |> where(contains("Repo.get!(_, _)")))
Exograph.explain(plan)
#=> %{
#=>   logical: %{required_terms: ["call.remote:Repo.get!/2"], ...},
#=>   physical: %{scan: {:term_index_scan, [...]}, filters: [:hydrate_fragments, :ex_ast_verify]},
#=>   estimated_candidates: 4,
#=>   warnings: []
#=> }
```

Standalone query explanations are still available:

```elixir
Exograph.explain("Repo.get!(User, id)")
#=> %{required: ["call.remote:Repo.get!/2", ...], verifier: :pattern, ...}
```

## Near duplicates

```elixir
{:ok, results} =
  Exograph.similar(index, """
  user
  |> cast(attrs, [:name])
  |> validate_required([:name])
  """, min_similarity: 0.8)
```

## Text and code-fact search

Literal source search uses ParadeDB when available, falling back to Postgres-backed
candidate retrieval plus source verification. Regex search verifies against
fragment source.

```elixir
Exograph.search_text(index, "/users/:id")
Exograph.search_text(index, ~r/Repo\.get!\(/)
Exograph.search_comments(index, "streaming chunks")
Exograph.search_definitions(index, "parse_resp")
Exograph.search_references(index, "Repo.transaction")
```

## Call graph search

Exograph persists Reach-derived call graph facts during indexing. Reach is used
as a library analysis engine; Exograph owns the stable IDs, package/file scope,
and Postgres persistence.

```elixir
Exograph.search_callers(index, "Repo.transaction/1")
Exograph.search_callees(index, "MyApp.Accounts.update_user/2")
```

## Mix tasks

Index the current project:

```bash
mix exograph.index --repo MyApp.Repo --migrate lib test
mix exograph.index --repo MyApp.Repo --migrate lib test --stats
mix exograph.index --repo MyApp.Repo --migrate --no-bm25 lib
mix exograph.index --repo MyApp.Repo --migrate --json lib
```

Search from the command line:

```bash
mix exograph.search 'Repo.get!(_, _)' --repo MyApp.Repo --migrate lib
mix exograph.search 'def _ do ... end' --repo MyApp.Repo --migrate lib --contains 'Repo.transaction(_)'
mix exograph.search 'def _ do ... end' --repo MyApp.Repo --migrate lib --contains 'Repo.transaction(_)' --not-contains 'IO.inspect(_)'
mix exograph.search 'Repo.get!(_, _)' --repo MyApp.Repo --migrate lib --explain
mix exograph.search '/users/:id' --repo MyApp.Repo --migrate lib --text
mix exograph.search 'Repo\.get!\(' --repo MyApp.Repo --migrate lib --regex
```

## Postgres + ParadeDB backend

Postgres is the production backend. Exograph uses Ecto migrations, schemas,
`Repo` operations, and transactions for packages, package versions, source files,
fragments, comments, definitions, references, and related code facts. Raw SQL is
kept to Postgres extensions and ParadeDB-specific BM25 operators/index creation.

```elixir
{:ok, index} =
  Exograph.index("lib/",
    repo: MyApp.Repo,
    migrate?: true,
    bm25?: true
  )
```

`backend: :postgres` is still accepted explicitly, but Postgres is the only
built-in backend. Public behavior and tests are validated against the real
Postgres backend.

This creates normalized Ecto-backed tables:

- `exograph_packages`
- `exograph_package_versions`
- `exograph_files`
- `exograph_fragments`
- `exograph_comments`
- `exograph_definitions`
- `exograph_references`

Fragments store `package_id`, `package_version_id`, and `file_id`; package name,
ecosystem, release metadata, source refs, and checksums live in package/version
tables and are joined when needed. Source text is stored once in `exograph_files`.

When ParadeDB's `pg_search` extension is available, `migrate?: true` also
creates BM25 indexes over source files, comments, definitions, and references.
Source files use ParadeDB's `pdb.source_code` tokenizer; symbol names use
`pdb.edge_ngram` for prefix/partial matching.

Index multiple package versions into the same backend by passing package release
identity:

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

Exograph.index("sources/req_llm-1.12.0",
  repo: MyApp.Repo,
  package_version: [ecosystem: :hex, name: "req_llm", version: "1.12.0"]
)

Exograph.search(index, "Repo.get!(_, _)",
  package_version_id: "hex:req_llm@1.11.0"
)
```

ParadeDB notes from the docs:

- `pg_search` is a Postgres extension backed by ParadeDB's Tantivy fork.
- BM25 indexes require a `key_field`, and that field must be first.
- Include columns used for filtering, grouping, ordering, or scoring in the BM25
  covering index.
- `|||` is match disjunction, `&&&` is match conjunction, and `pdb.score(id)`
  exposes BM25 relevance.
- ParadeDB updates its BM25 index transactionally with Postgres writes and WAL.

CLI usage:

```bash
mix exograph.index --backend postgres --repo MyApp.Repo --migrate lib test
mix exograph.search 'Repo.get!(_, _)' --backend postgres --repo MyApp.Repo --migrate lib
mix exograph.search 'running shoes' --text --backend postgres --repo MyApp.Repo --migrate lib
```

The test suite runs real indexing, structural search, selector search, text
search, tree-node lookup, code-fact lookup, and similarity search against
Postgres. Set a database URL when the default local Postgres database is not
available:

```bash
EXOGRAPH_DATABASE_URL=postgres://postgres:postgres@localhost:5432/exograph_test \
  mix test
```

## Storage layout

`Exograph.Index` separates execution by concern:

- Postgres inverted index: structural term candidate retrieval from fragment rows
- fragment store: AST blobs, ExDNA hashes, symbols, and file joins
- source files: source text and aggregated comment text stored once per file
- code facts: normalized comments, definitions, references, graph nodes, and call edges
- tree access: derived lazily from stored AST fragments
- verifier: `ExAST.Pattern` / `ExAST.Query`
- similarity: ExDNA structural reranking
