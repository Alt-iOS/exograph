defmodule ExographDSLFragmentFieldTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_fragment_field_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "filters fragment queries by fragment fields", %{opts: opts} do
    path =
      fixture("fragment_fields.ex", """
      defmodule Demo.FragmentFields do
        def public_fun, do: Repo.transaction(fn -> :ok end)
        defp private_fun, do: Repo.transaction(fn -> :ok end)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        where: f.kind == :defp,
        where: f.name == "private_fun",
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

  test "filters joined fragment queries by fragment fields", %{opts: opts} do
    path =
      fixture("fragment_join_fields.ex", """
      defmodule Demo.FragmentJoinFields do
        def public_fun, do: Repo.transaction(fn -> :ok end)
        defp private_fun, do: Repo.transaction(fn -> :ok end)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: e in assoc(f, :calls),
        where: f.kind == :defp,
        where: e.callee_qualified_name == "Repo.transaction/1",
        where: matches(f, "defp _ do ... end")
      )

    {:ok, results} = Exograph.all(index, query)

    assert Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:defp, _, [{:private_fun, _, _} | _]}, node)
           end)

    refute Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:public_fun, _, _} | _]}, node)
           end)
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-fragment-field-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
