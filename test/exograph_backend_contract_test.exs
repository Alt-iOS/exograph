defmodule ExographBackendContractTest do
  use ExUnit.Case, async: false

  alias Exograph.BackendContract

  @memory_profile %{
    name: :memory,
    module: Demo.BackendContract.Memory,
    opts: [
      backend: :memory,
      package_version: [ecosystem: :hex, name: "demo_memory", version: "1.0.0"]
    ],
    expected: %{
      inverted: Exograph.InvertedIndex.Memory,
      fragment_store: Exograph.FragmentStore.Memory,
      tree_store: Exograph.TreeStore.Memory
    }
  }

  @tantivy_profile %{
    name: :tantivy,
    module: Demo.BackendContract.Tantivy,
    opts: [
      backend: :tantivy,
      index_path:
        Path.join(
          System.tmp_dir!(),
          "exograph-contract-tantivy-#{System.unique_integer([:positive])}"
        ),
      package_version: [ecosystem: :hex, name: "demo_tantivy", version: "1.0.0"]
    ],
    expected: %{
      inverted: Exograph.InvertedIndex.TantivyEx,
      fragment_store: Exograph.FragmentStore.Memory,
      tree_store: Exograph.TreeStore.Memory
    }
  }

  @postgres_profile %{
    name: :postgres,
    module: Demo.BackendContract.Postgres,
    opts: [
      backend: :postgres,
      repo: Exograph.TestRepo,
      prefix: "exograph_contract_#{System.unique_integer([:positive])}",
      migrate?: true,
      bm25?: false,
      package_version: [ecosystem: :hex, name: "demo_postgres", version: "1.0.0"]
    ],
    expected: %{
      inverted: Exograph.InvertedIndex.Postgres,
      fragment_store: Exograph.FragmentStore.Postgres,
      tree_store: Exograph.TreeStore.Postgres
    }
  }

  for profile <- [@memory_profile, @tantivy_profile, @postgres_profile] do
    @profile profile

    test "#{profile.name} backend profile wires expected behaviour modules" do
      BackendContract.assert_profile(@profile, @profile.expected)
    end
  end

  for profile <- [@memory_profile, @tantivy_profile] do
    @profile profile

    test "#{profile.name} backend satisfies real indexing and search contract" do
      BackendContract.assert_real_indexing_and_search(@profile)
    end
  end

  @tag :postgres
  test "postgres backend satisfies real indexing and search contract when database is available" do
    url = System.get_env("EXOGRAPH_DATABASE_URL")

    case BackendContract.start_postgres_repo(url) do
      {:ok, _pid} ->
        try do
          BackendContract.assert_real_indexing_and_search(@postgres_profile)
          BackendContract.assert_postgres_package_rows(@postgres_profile.opts)
        after
          BackendContract.drop_postgres_prefix(@postgres_profile.opts)
        end

      {:error, _reason} ->
        flunk("set EXOGRAPH_DATABASE_URL to run the Postgres backend contract")
    end
  end
end
