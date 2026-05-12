#!/usr/bin/env elixir

# Index Hex package sources into Exograph and run sample queries.
#
# Prerequisites:
#   - Postgres running locally
#   - Hex package sources extracted into a directory, one subdirectory per package
#     (e.g. ~/hex-sources/phoenix-1.7.0/, ~/hex-sources/ecto-3.13.5/, ...)
#
# Usage:
#   EXOGRAPH_SOURCE_ROOT=~/hex-sources mix run examples/index_hex_corpus.exs
#
# Options (env vars):
#   EXOGRAPH_SOURCE_ROOT  — directory containing package subdirectories (required)
#   EXOGRAPH_DATABASE_URL — Postgres URL (default: postgres://localhost:5432/postgres)
#   EXOGRAPH_PREFIX       — table prefix (default: exograph)
#   EXOGRAPH_LIMIT        — max packages to index (default: all)
#   EXOGRAPH_REACH        — set to "false" to disable Reach extraction

Application.ensure_all_started(:exograph)

source_root = System.get_env("EXOGRAPH_SOURCE_ROOT") || raise("Set EXOGRAPH_SOURCE_ROOT")
database_url = System.get_env("EXOGRAPH_DATABASE_URL", "postgres://localhost:5432/postgres")
prefix = System.get_env("EXOGRAPH_PREFIX", "exograph")
limit = if l = System.get_env("EXOGRAPH_LIMIT"), do: String.to_integer(l), else: :infinity
extractors = if System.get_env("EXOGRAPH_REACH") == "false", do: [:ex_ast], else: [:ex_ast, :reach]

{:ok, _pid} =
  Exograph.TestRepo.start_link(
    url: database_url,
    pool_size: 10,
    ssl: false,
    log: false,
    timeout: 120_000
  )

packages =
  source_root
  |> File.ls!()
  |> Enum.map(&Path.join(source_root, &1))
  |> Enum.filter(&File.dir?/1)
  |> Enum.sort()
  |> then(fn pkgs -> if limit == :infinity, do: pkgs, else: Enum.take(pkgs, limit) end)

IO.puts("Indexing #{length(packages)} packages from #{source_root}")
IO.puts("  prefix=#{prefix} extractors=#{inspect(extractors)}")

started = System.monotonic_time(:millisecond)

for {path, ordinal} <- Enum.with_index(packages, 1) do
  basename = Path.basename(path)

  {name, version} =
    case Regex.run(~r/^(.+)-(\d[^-]*)$/, basename) do
      [_, n, v] -> {n, v}
      _ -> {basename, "0.0.0"}
    end

  opts = [
    repo: Exograph.TestRepo,
    prefix: prefix,
    bm25?: false,
    min_mass: 8,
    migrate?: ordinal == 1,
    extractors: extractors,
    package_version: [
      ecosystem: :hex,
      name: name,
      version: version,
      source_ref: "hex:#{name}:#{version}"
    ]
  ]

  case Exograph.index(path, opts) do
    {:ok, _} ->
      if rem(ordinal, 50) == 0 do
        elapsed = System.monotonic_time(:millisecond) - started
        rate = Float.round(ordinal / (elapsed / 1000), 2)
        IO.puts("  [#{ordinal}/#{length(packages)}] #{name}@#{version} (#{rate} pkg/s)")
      end

    {:error, reason} ->
      IO.puts("  FAIL #{name}@#{version}: #{inspect(reason)}")
  end
end

total_ms = System.monotonic_time(:millisecond) - started
IO.puts("\nDone in #{Float.round(total_ms / 1000, 1)}s")

# --- Sample queries ---

{:ok, index} =
  Exograph.index([],
    repo: Exograph.TestRepo,
    prefix: prefix,
    migrate?: false,
    bm25?: false
  )

import Exograph.DSL
import ExAST.Query

IO.puts("\n=== Sample queries ===\n")

queries = [
  {"Structural: Repo.get!(_, _)",
   fn -> Exograph.search(index, "Repo.get!(_, _)", limit: 5) end},
  {"Structural: def + contains Repo.transaction",
   fn ->
     Exograph.search(
       index,
       from("def _ do ... end") |> where(contains("Repo.transaction(_)")),
       limit: 5
     )
   end},
  {"DSL: definitions named 'handle_*'",
   fn ->
     Exograph.all(
       index,
       from(d in Definition, where: prefix_search(d.name, "handle")),
       limit: 5
     )
   end},
  {"DSL: fragment + reference join",
   fn ->
     q =
       from(f in Fragment,
         join: r in assoc(f, :references),
         where: r.qualified_name == "Enum.map/2",
         where: matches(f, "def _ do ... end"),
         select: {f, r}
       )

     Exograph.all(index, q, limit: 5)
   end},
  {"Call graph: callers of Enum.reduce/3",
   fn -> Exograph.search_callers(index, "Enum.reduce/3", limit: 5) end}
]

for {label, fun} <- queries do
  {us, result} = :timer.tc(fun)

  case result do
    {:ok, hits} ->
      IO.puts("#{label}")
      IO.puts("  #{length(hits)} results in #{Float.round(us / 1000, 2)}ms")

      for hit <- Enum.take(hits, 3) do
        case hit do
          %Exograph.Hit{fragment: f, match: m} ->
            IO.puts("  → #{Path.basename(f.file)}:#{m.line} #{f.kind} #{f.name || ""}")

          %Exograph.CallEdge{caller_qualified_name: caller, callee_qualified_name: callee} ->
            IO.puts("  → #{caller} calls #{callee}")

          %{definition: d} ->
            IO.puts("  → #{d.qualified_name} (#{d.kind})")

          other ->
            IO.puts("  → #{inspect(other, limit: 80)}")
        end
      end

      IO.puts("")

    {:error, reason} ->
      IO.puts("#{label}: ERROR #{inspect(reason)}\n")
  end
end
