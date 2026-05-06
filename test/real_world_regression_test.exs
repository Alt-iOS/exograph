defmodule Exograph.RealWorldRegressionTest do
  use ExUnit.Case, async: true

  test "indexes dynamic aliases such as __MODULE__ without crashing" do
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

    assert {:ok, index} = Exograph.index(path, min_mass: 4)
    assert [_ | _] = index.fragment_store_backend.all(index.fragment_store)
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
