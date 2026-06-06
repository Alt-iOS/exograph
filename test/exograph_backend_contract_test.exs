defmodule ExographBackendContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Exograph.DSL

  alias Exograph.{BackendContract, DuckDBSupport, PostgresSupport}

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

  describe "DuckDB backend query plans" do
    @describetag :duckdb
    setup do
      database = DuckDBSupport.start_managed_repo!(log: :debug)
      prefix = "exograph_duckdb_contract_#{System.unique_integer([:positive])}"
      opts = DuckDBSupport.opts(prefix)

      on_exit(fn ->
        capture_log(fn -> DuckDBSupport.drop_prefix(prefix) end)
        File.rm_rf(database)
      end)

      {:ok, opts: opts}
    end

    test "structural queries use the term table and avoid wide fragment payload", %{opts: opts} do
      path =
        fixture("structural.ex", """
        defmodule Demo.Structural do
          def handle_call(message, _from, state) do
            {:reply, message, state}
          end
        end
        """)

      index = index_without_log(path, opts)

      query =
        from(f in Fragment,
          where: matches(f, "def handle_call(_, _, _) do ... end"),
          limit: 5
        )

      log = capture_log(fn -> assert {:ok, [_ | _]} = Exograph.all(index, query) end)

      assert log =~ "fragment_terms"
      assert log =~ ~s|"name" = ?|
      assert log =~ ~s|"arity" = ?|
      refute log =~ ~s|"terms" AS "terms"|
      refute log =~ ~s|"sub_hashes" AS "sub_hashes"|
    end

    test "reference joins use the narrow DuckDB lateral plan", %{opts: opts} do
      path =
        fixture("reference_join.ex", """
        defmodule Demo.ReferenceJoin do
          def first(items) do
            Enum.map(items, fn item -> item end)
          end

          def second(items) do
            Enum.map(items, fn item -> item end)
          end
        end
        """)

      index = index_without_log(path, opts)

      query =
        from(f in Fragment,
          join: r in assoc(f, :references),
          where: r.qualified_name == "Enum.map/2",
          where: f.kind == :def,
          limit: 5
        )

      log = capture_log(fn -> assert {:ok, [_ | _]} = Exograph.all(index, query) end)

      assert log =~ "INNER JOIN LATERAL"
      refute log =~ "DISTINCT ON"
      refute log =~ ~s|"ast" AS "ast"|
      refute log =~ ~s|"terms" AS "terms"|
      refute log =~ ~s|"sub_hashes" AS "sub_hashes"|
    end
  end

  defp index_without_log(path, opts) do
    parent = self()

    capture_log(fn ->
      {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))
      send(parent, {:indexed, index})
    end)

    assert_receive {:indexed, index}
    index
  end

  defp fixture(name, source) do
    dir = Path.join(System.tmp_dir!(), "exograph-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
