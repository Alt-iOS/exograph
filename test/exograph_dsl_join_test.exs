defmodule ExographDSLJoinTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_join_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "joins fragments to references before structural verification", %{opts: opts} do
    path =
      fixture("fragment_reference_join.ex", """
      defmodule Demo.FragmentReferenceJoin do
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
        join: r in assoc(f, :references),
        where: r.qualified_name == "Repo.transaction/1",
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

  test "joins fragments to references with prefix search", %{opts: opts} do
    path =
      fixture("fragment_reference_prefix_join.ex", """
      defmodule Demo.FragmentReferencePrefixJoin do
        def get_user(id), do: Repo.get!(User, id)
        def all_users, do: Repo.all(User)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: r in assoc(f, :references),
        where: prefix_search(r.qualified_name, "Repo.get"),
        where: matches(f, "def _ do ... end")
      )

    {:ok, results} = Exograph.all(index, query)

    assert Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:get_user, _, _} | _]}, node)
           end)

    refute Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:all_users, _, _} | _]}, node)
           end)
  end

  defp fixture(name, source) do
    dir = Path.join(System.tmp_dir!(), "exograph-dsl-join-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
