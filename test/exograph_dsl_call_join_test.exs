defmodule ExographDSLCallJoinTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_call_join_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "joins fragments to Reach call edges before structural verification", %{opts: opts} do
    path =
      fixture("fragment_call_join.ex", """
      defmodule Demo.FragmentCallJoin do
        def safe(user) do
          Repo.transaction(fn -> user end)
        end

        def noisy(user) do
          Repo.get!(User, user)
        end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: e in assoc(f, :calls),
        where: e.callee_qualified_name == "Repo.transaction/1",
        where: matches(f, "def _ do ... end")
      )

    {:ok, results} = Exograph.all(index, query)

    assert Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:safe, _, _} | _]}, node)
           end)

    refute Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:noisy, _, _} | _]}, node)
           end)
  end

  test "joins definitions to Reach call edges", %{opts: opts} do
    path =
      fixture("definition_call_join.ex", """
      defmodule Demo.DefinitionCallJoin do
        def with_transaction(user), do: Repo.transaction(fn -> user end)
        def with_get(id), do: Repo.get!(User, id)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(d in Definition,
        join: e in assoc(d, :calls),
        where: e.callee_qualified_name == "Repo.transaction/1"
      )

    assert {:ok, [%Exograph.DefinitionHit{} = hit]} = Exograph.all(index, query)
    assert hit.definition.qualified_name == "Demo.DefinitionCallJoin.with_transaction/1"
  end

  test "joins definitions to Reach call edges with definition predicates", %{opts: opts} do
    path =
      fixture("definition_call_join_filtered.ex", """
      defmodule Demo.DefinitionCallJoinFiltered do
        def public_transaction(user), do: Repo.transaction(fn -> user end)
        defp private_transaction(user), do: Repo.transaction(fn -> user end)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(d in Definition,
        join: e in assoc(d, :calls),
        where: d.kind == :defp,
        where: e.callee_qualified_name == "Repo.transaction/1"
      )

    assert {:ok, [%Exograph.DefinitionHit{} = hit]} = Exograph.all(index, query)

    assert hit.definition.qualified_name ==
             "Demo.DefinitionCallJoinFiltered.private_transaction/1"
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-call-join-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
