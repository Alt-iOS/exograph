defmodule ExographDSLSelectTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_select_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "selects fragment hit and joined call edge", %{opts: opts} do
    path =
      fixture("select_call.ex", """
      defmodule Demo.SelectCall do
        def update_user(user), do: Repo.transaction(fn -> user end)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: e in assoc(f, :calls),
        where: e.callee_qualified_name == "Repo.transaction/1",
        where: matches(f, "def _ do ... end"),
        select: {f, e}
      )

    assert {:ok, [{%Exograph.Hit{} = hit, %Exograph.CallEdge{} = edge}]} =
             Exograph.all(index, query)

    assert hit.fragment.file == path
    assert edge.callee_qualified_name == "Repo.transaction/1"
  end

  test "selects only joined reference", %{opts: opts} do
    path =
      fixture("select_reference.ex", """
      defmodule Demo.SelectReference do
        def get_user(id), do: Repo.get!(User, id)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: r in assoc(f, :references),
        where: r.qualified_name == "Repo.get!/2",
        where: matches(f, "def _ do ... end"),
        select: r
      )

    assert {:ok, [%Exograph.Reference{} = reference]} = Exograph.all(index, query)
    assert reference.qualified_name == "Repo.get!/2"
  end

  defp fixture(name, source) do
    dir =
      Path.join(System.tmp_dir!(), "exograph-dsl-select-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
