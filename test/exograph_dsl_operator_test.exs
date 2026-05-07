defmodule ExographDSLOperatorTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_operator_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "filters fragments with in and comparison predicates", %{opts: opts} do
    path =
      fixture("fragment_operators.ex", """
      defmodule Demo.FragmentOperators do
        def public_fun(value), do: Repo.transaction(fn -> value end)
        defp private_fun(value), do: Repo.transaction(fn -> value end)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        where: f.kind in [:defp],
        where: f.mass > 4,
        where: contains(f, "Repo.transaction(_)")
      )

    {:ok, results} = Exograph.all(index, query)

    assert Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:defp, _, [{:private_fun, _, _} | _]}, node)
           end)

    refute Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:public_fun, _, _} | _]}, node)
           end)
  end

  test "filters definitions with in predicates", %{opts: opts} do
    path =
      fixture("definition_operators.ex", """
      defmodule Demo.DefinitionOperators do
        def parse_one(value), do: value
        defp parse_two(value), do: value
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(d in Definition,
        where: d.kind in [:defp],
        where: prefix_search(d.name, "parse")
      )

    assert {:ok, [%Exograph.DefinitionHit{} = hit]} = Exograph.all(index, query)
    assert hit.definition.name == "parse_two"
  end

  test "filters joined call edges with comparison predicates", %{opts: opts} do
    path =
      fixture("call_edge_operators.ex", """
      defmodule Demo.CallEdgeOperators do
        def update_user(user) do
          Repo.transaction(fn -> user end)
        end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: e in assoc(f, :calls),
        where: e.callee_qualified_name == "Repo.transaction/1",
        where: e.line >= 2,
        where: matches(f, "def _ do ... end"),
        select: {f, e}
      )

    assert {:ok, [{%Exograph.Hit{}, %Exograph.CallEdge{} = edge}]} = Exograph.all(index, query)
    assert edge.callee_qualified_name == "Repo.transaction/1"
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-operator-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
