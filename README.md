# Exograph

Structural search and code intelligence for Elixir.

Exograph combines:

- `ex_ast` patterns and SQL-like queries for exact AST matching
- `ex_dna` fingerprints for structural fragments and near-duplicate search
- OpenGrok-style fields (`full`, `defs`, `refs`, `path`, `type`) in an inverted-index boundary
- a fragment store for AST/source truth
- a tree store with preorder/postorder AST node metadata
- primary Ecto/Postgres storage with optional ParadeDB (`pg_search`) BM25 retrieval
- optional TantivyEx-backed local candidate retrieval

## Prototype

```elixir
{:ok, index} = Exograph.index("lib/", min_mass: 8)
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

Selector alternatives and sibling/position predicates are compiled into
candidate terms too:

```elixir
from(["def _ do ... end", "defp _ do ... end"])
|> where(follows("@doc _"))
|> where(first())
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

## Text search

Literal search uses trigram candidate checks before source verification. Regex
search verifies directly against fragment source.

```elixir
Exograph.search_text(index, "/users/:id")
Exograph.search_text(index, ~r/Repo\.get!\(/)
```

## Mix task

Index the current project:

```bash
mix exograph.index
mix exograph.index lib test --stats
mix exograph.index --backend tantivy --index-path .exograph/tantivy lib
mix exograph.index --json lib
```

Search from the command line:

```bash
mix exograph.search 'Repo.get!(_, _)' lib
mix exograph.search 'def _ do ... end' lib --contains 'Repo.transaction(_)'
mix exograph.search 'def _ do ... end' lib --contains 'Repo.transaction(_)' --not-contains 'IO.inspect(_)'
mix exograph.search 'Repo.get!(_, _)' lib --explain
mix exograph.search '/users/:id' lib --text
mix exograph.search 'Repo\\.get!\\(' lib --regex
```

## Postgres + ParadeDB backend

Postgres is the primary durable backend. Exograph uses Ecto schemas, `Repo`
operations, and transactions for fragments and AST tree nodes. Raw SQL is kept to
DDL and ParadeDB-specific BM25 operators/index creation.

```elixir
{:ok, index} =
  Exograph.index("lib/",
    backend: :postgres,
    repo: MyApp.Repo,
    migrate?: true,
    bm25?: true
  )
```

Backends are high-level behaviour profiles. Built-in profiles are
`backend: :postgres`, `backend: :memory`, and `backend: :tantivy`; custom profiles
can implement `Exograph.Backend` to wire an inverted index, fragment store, and
tree store together.

This creates Ecto-backed tables named `exograph_fragments` and
`exograph_tree_nodes`. When ParadeDB's `pg_search` extension is available,
`migrate?: true` also creates a Tantivy-powered BM25 covering index:

```sql
CREATE INDEX exograph_fragments_bm25_idx
ON exograph_fragments
USING bm25 (id, source, file, kind, name, terms_text, defs_text, refs_text,
            modules_text, functions_text, aliases_text, structs_text, atoms_text)
WITH (key_field = 'id');
```

ParadeDB notes from the docs:

- `pg_search` is a Postgres extension backed by ParadeDB's Tantivy fork.
- BM25 indexes require a `key_field`, and that field must be first.
- Include columns used for filtering, grouping, ordering, or scoring in the BM25
  covering index.
- `|||` is match disjunction, `&&&` is match conjunction, and
  `paradedb.score(id)` exposes BM25 relevance.
- ParadeDB updates its BM25 index transactionally with Postgres writes and WAL.

CLI usage:

```bash
mix exograph.index --backend postgres --repo MyApp.Repo --migrate lib test
mix exograph.search 'Repo.get!(_, _)' --backend postgres --repo MyApp.Repo lib
mix exograph.search 'running shoes' --text --backend postgres --repo MyApp.Repo lib
```

## TantivyEx backend

```elixir
{:ok, index} =
  Exograph.index("lib/",
    backend: :tantivy,
    index_path: ".exograph/tantivy"
  )
```

The TantivyEx backend stores candidate fields such as:

- `full`
- `file` / `path_text`
- `defs`, `refs`, `modules`, `functions`, `aliases`, `structs`, `atoms`
- `terms` for AST query candidate retrieval
- `subhashes` for future near-duplicate candidate retrieval
- `trigrams` for future indexed substring/regex candidate retrieval

AST/source are still verified from the fragment store.

## Storage layout

`Exograph.Index` separates storage by concern:

- inverted index: candidate retrieval (`Postgres`, `Memory`, or `TantivyEx`)
- fragment store: source snippets, AST blobs, ExDNA hashes, symbols
- tree store: AST nodes with parent/child and preorder/postorder metadata
- verifier: `ExAST.Pattern` / `ExAST.Query`
- similarity: ExDNA structural reranking
