defmodule ExographBackendContractTest do
  use ExUnit.Case, async: false

  alias Exograph.{BackendContract, PostgresSupport}

  @tag :postgres
  test "postgres backend satisfies real indexing and search contract" do
    PostgresSupport.start_repo!()

    opts =
      PostgresSupport.opts("exograph_contract_#{System.unique_integer([:positive])}",
        package_version: [ecosystem: :hex, name: "demo_postgres", version: "1.0.0"]
      )

    try do
      BackendContract.assert_real_indexing_and_search(opts)
      BackendContract.assert_postgres_package_rows(opts)
      BackendContract.assert_postgres_code_fact_rows(opts)
    after
      BackendContract.drop_postgres_prefix(opts)
    end
  end
end
