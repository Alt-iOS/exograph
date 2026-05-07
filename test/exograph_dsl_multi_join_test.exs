defmodule ExographDSLMultiJoinTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_multi_join_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "joins fragments to definitions and calls", %{opts: opts} do
    path =
      fixture("multi_join.ex", """
      defmodule Demo.MultiJoin do
        def public_transaction(user) do
          Repo.transaction(fn -> user end)
        end

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
        join: e in assoc(f, :calls),
        where: d.kind == :defp,
        where: e.callee_qualified_name == "Repo.transaction/1",
        where: matches(f, "defp _ do ... end"),
        select: {f, d, e}
      )

    assert {:ok,
            [
              {%Exograph.Hit{} = hit, %Exograph.Definition{} = definition,
               %Exograph.CallEdge{} = edge}
            ]} =
             Exograph.all(index, query)

    assert definition.qualified_name == "Demo.MultiJoin.private_transaction/1"
    assert edge.callee_qualified_name == "Repo.transaction/1"

    assert match?({:defp, _, [{:private_transaction, _, _} | _]}, hit.match.node)
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-multi-join-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
