# Package Indexing

Exograph can index multiple package versions into the same Postgres backend. This
was one of the original motivations for the project: test ExAST and Reach on
larger real-world Elixir package sets and make the resulting facts queryable.

## Package version identity

Pass package release identity while indexing:

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
```

Package and package-version records are normalized separately from files and
fragments.

## Scoped queries

Use package/version options to restrict search:

```elixir
Exograph.search(index, "Repo.get!(_, _)",
  package_version_id: "hex:req_llm@1.11.0"
)
```

The DSL and code-fact search APIs use the same underlying scope fields.

## Use cases

Package indexing is useful when you want to:

- compare code patterns across versions
- search a local Hex package corpus
- benchmark ExAST or Reach on real code
- build local/self-hosted package code intelligence
- find API usage examples across many libraries
