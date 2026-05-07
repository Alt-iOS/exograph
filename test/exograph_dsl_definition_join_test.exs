defmodule ExographDSLDefinitionJoinTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_definition_join_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "joins fragments to definitions", %{opts: opts} do
    path =
      fixture("fragment_definition_join.ex", """
      defmodule Demo.FragmentDefinitionJoin do
        def public_fun, do: :ok
        defp private_fun, do: :ok
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: d in assoc(f, :definitions),
        where: d.kind == :defp,
        where: d.name == "private_fun",
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

  test "joins fragments to definitions with prefix search", %{opts: opts} do
    path =
      fixture("fragment_definition_prefix_join.ex", """
      defmodule Demo.FragmentDefinitionPrefixJoin do
        def parse_response_chunk(chunk), do: chunk
        def unrelated(value), do: value
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: d in assoc(f, :definitions),
        where: prefix_search(d.name, "parse_resp"),
        where: matches(f, "def _ do ... end")
      )

    {:ok, results} = Exograph.all(index, query)

    assert Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:parse_response_chunk, _, _} | _]}, node)
           end)

    refute Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:unrelated, _, _} | _]}, node)
           end)
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-definition-join-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
