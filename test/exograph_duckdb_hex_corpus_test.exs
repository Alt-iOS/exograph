defmodule ExographDuckDBHexCorpusTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport

  @moduletag :integration

  test "duckdb backend indexes Hex packages through the corpus pipeline" do
    if System.get_env("QUACKDB_TEST_URI") do
      DuckDBSupport.start_repo!()
      prefix = "exograph_duckdb_hex_#{System.unique_integer([:positive])}"
      opts = DuckDBSupport.opts(prefix, extractors: [:ex_ast])

      results =
        Exograph.Hex.Corpus.index(
          Keyword.merge(opts,
            mode: :top,
            limit: 1,
            concurrency: 1,
            min_mass: 4,
            resume: false,
            bm25?: false,
            timeout: 120_000
          )
        )

      assert results.ok >= 1
      assert [_fragment | _] = indexed_fragments(prefix)
    end
  end

  defp indexed_fragments(prefix) do
    {:ok, index} =
      Exograph.index([],
        backend: :duckdb,
        repo: Exograph.DuckDBRepo,
        prefix: prefix,
        migrate?: false
      )

    Exograph.Postgres.FragmentStore.all(index.fragment_store)
  end
end
