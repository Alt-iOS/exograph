defmodule ExographDSLCallEdgeTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_call_edge_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "queries call edges by callee", %{opts: opts} do
    path =
      fixture("call_edges.ex", """
      defmodule Demo.CallEdgeDSL do
        def update_user(user) do
          Repo.transaction(fn -> user end)
        end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(e in CallEdge,
        where: e.callee_qualified_name == "Repo.transaction/1"
      )

    assert {:ok, [%Exograph.CallEdgeHit{} = hit]} = Exograph.all(index, query)
    assert hit.call_edge.callee_qualified_name == "Repo.transaction/1"
    assert hit.call_edge.caller_qualified_name == "Demo.CallEdgeDSL.update_user/1"
  end

  test "queries call edges with prefix search", %{opts: opts} do
    path =
      fixture("call_edge_prefix.ex", """
      defmodule Demo.CallEdgePrefixDSL do
        def get_user(id), do: Repo.get!(User, id)
        def all_users, do: Repo.all(User)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(e in CallEdge,
        where: prefix_search(e.caller_qualified_name, "Demo.CallEdgePrefixDSL.get")
      )

    assert {:ok, [%Exograph.CallEdgeHit{} = hit]} = Exograph.all(index, query)
    assert hit.call_edge.caller_qualified_name == "Demo.CallEdgePrefixDSL.get_user/1"
    assert hit.call_edge.callee_qualified_name == "Repo.get!/2"
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-call-edge-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
