defmodule ExographBackendContractTest do
  use ExUnit.Case, async: false

  alias Exograph.{BackendContract, PostgresSupport}

  @tag :postgres
  test "postgres backend profile wires expected behaviour modules" do
    profile = postgres_profile()
    BackendContract.assert_profile(profile, profile.expected)
  end

  @tag :postgres
  test "postgres backend satisfies real indexing and search contract" do
    PostgresSupport.start_repo!()
    profile = postgres_profile()

    try do
      BackendContract.assert_real_indexing_and_search(profile)
      BackendContract.assert_postgres_package_rows(profile.opts)
      BackendContract.assert_postgres_code_fact_rows(profile.opts)
    after
      BackendContract.drop_postgres_prefix(profile.opts)
    end
  end

  defp postgres_profile do
    opts =
      PostgresSupport.opts("exograph_contract_#{System.unique_integer([:positive])}",
        package_version: [ecosystem: :hex, name: "demo_postgres", version: "1.0.0"]
      )

    %{
      name: :postgres,
      module: Demo.BackendContract.Postgres,
      opts: opts,
      expected: %{
        inverted: Exograph.InvertedIndex.Postgres,
        fragment_store: Exograph.FragmentStore.Postgres,
        tree_store: Exograph.TreeStore.Postgres
      }
    }
  end
end
