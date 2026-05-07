defmodule ExographDSLDefinitionTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_definition_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "queries definitions with prefix search", %{opts: opts} do
    path =
      fixture("definitions.ex", """
      defmodule Demo.DefinitionDSL do
        def parse_response_chunk(chunk), do: chunk
        def unrelated(value), do: value
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(d in Definition,
        where: prefix_search(d.name, "parse_resp")
      )

    assert {:ok, [%Exograph.DefinitionHit{} = hit]} = Exograph.all(index, query)
    assert hit.definition.name == "parse_response_chunk"
    assert hit.definition.qualified_name == "Demo.DefinitionDSL.parse_response_chunk/1"
    assert hit.fragment.name == "parse_response_chunk"
  end

  test "queries definitions with field equality", %{opts: opts} do
    path =
      fixture("definition_eq.ex", """
      defmodule Demo.DefinitionEqualityDSL do
        def public_fun, do: :ok
        defp private_fun, do: :ok
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(d in Definition,
        where: d.kind == :defp,
        where: d.qualified_name == "Demo.DefinitionEqualityDSL.private_fun/0"
      )

    assert {:ok, [%Exograph.DefinitionHit{} = hit]} = Exograph.all(index, query)
    assert hit.definition.kind == :defp
    assert hit.definition.name == "private_fun"
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-definition-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
