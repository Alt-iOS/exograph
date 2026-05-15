defmodule Exograph.RealWorldRegressionTest do
  use ExUnit.Case, async: false

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_regression_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "indexes module-attribute callees from Reach without crashing", %{opts: opts} do
    path =
      fixture("module_attribute_callee.ex", """
      defmodule Demo.ModuleAttributeCallee do
        @schema_provider Demo.SchemaProvider

        def schema do
          @schema_provider.schema()
        end
      end
      """)

    assert {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))
    assert [_ | _] = Exograph.FragmentStore.Postgres.all(index.fragment_store)
  end

  test "indexes dynamic aliases such as __MODULE__ without crashing", %{opts: opts} do
    path =
      fixture("dynamic_alias.ex", """
      defmodule Demo.DynamicAlias do
        alias __MODULE__.Nested

        defstruct [:id]

        def nested(value) do
          %Nested{id: value}
        end
      end
      """)

    assert {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))
    assert [_ | _] = Exograph.FragmentStore.Postgres.all(index.fragment_store)
  end

  defp fixture(name, source) do
    dir =
      Path.join(System.tmp_dir!(), "exograph-regression-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
