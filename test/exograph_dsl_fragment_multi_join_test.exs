defmodule ExographDSLFragmentMultiJoinTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.{CallEdge, Definition, Hit, Reference}
  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_frag_multi_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "joins fragments with definitions, references, and calls", %{opts: opts} do
    path =
      fixture("fragment_multi_join.ex", """
      defmodule Demo.FragmentMultiJoin do
      defp private_transaction(user) do
        Repo.transaction(fn -> user end)
      end

      defp private_get(id) do
        Repo.get!(User, id)
      end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: d in assoc(f, :definitions),
        join: r in assoc(f, :references),
        join: e in assoc(f, :calls),
        where: d.kind == :defp,
        where: r.qualified_name == "Repo.transaction/1",
        where: e.callee_qualified_name == "Repo.transaction/1",
        where: matches(f, "defp _ do ... end"),
        select: {f, d, r, e}
      )

    assert {:ok,
            [
              {%Hit{} = hit, %Definition{} = definition, %Reference{} = reference,
               %CallEdge{} = call_edge}
            ]} =
             Exograph.all(index, query)

    assert hit.fragment.name == "private_transaction"
    assert definition.qualified_name == "Demo.FragmentMultiJoin.private_transaction/1"
    assert reference.qualified_name == "Repo.transaction/1"
    assert call_edge.callee_qualified_name == "Repo.transaction/1"
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-fragment-multi-join-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
