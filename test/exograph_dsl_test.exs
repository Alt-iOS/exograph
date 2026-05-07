defmodule ExographDSLTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "queries fragments with Ecto-shaped structural predicates", %{opts: opts} do
    path =
      fixture("dsl.ex", """
      defmodule Demo.DSL do
        def safe do
          Repo.transaction(fn -> :ok end)
        end

        def noisy do
          IO.inspect(:debug)
        end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        where: matches(f, "def _ do ... end"),
        where: contains(f, "Repo.transaction(_)")
      )

    {:ok, results} = Exograph.all(index, query)

    assert Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:safe, _, _} | _]}, node)
           end)

    refute Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:noisy, _, _} | _]}, node)
           end)
  end

  test "fragment DSL query can use contains without an explicit structural match", %{opts: opts} do
    path =
      fixture("contains_only.ex", """
      defmodule Demo.ContainsOnly do
        def one, do: Repo.get!(User, 1)
        def two, do: :ok
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        where: contains(f, "Repo.get!(_, _)")
      )

    {:ok, results} = Exograph.all(index, query)

    assert Enum.any?(results, &(&1.fragment.file == path))
  end

  defp fixture(name, source) do
    dir = Path.join(System.tmp_dir!(), "exograph-dsl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
