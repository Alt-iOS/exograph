defmodule ExographDSLReferenceTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_reference_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "queries references with field equality", %{opts: opts} do
    path =
      fixture("references.ex", """
      defmodule Demo.ReferenceDSL do
        def update_user(user) do
          Repo.transaction(fn -> user end)
        end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(r in Reference,
        where: r.qualified_name == "Repo.transaction/1"
      )

    assert {:ok, [%Exograph.ReferenceHit{} = hit]} = Exograph.all(index, query)
    assert hit.reference.qualified_name == "Repo.transaction/1"
    assert hit.fragment.file == path
  end

  test "queries references with prefix search", %{opts: opts} do
    path =
      fixture("reference_prefix.ex", """
      defmodule Demo.ReferencePrefixDSL do
        def get_user(id), do: Repo.get!(User, id)
        def all_users, do: Repo.all(User)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(r in Reference,
        where: prefix_search(r.qualified_name, "Repo.get")
      )

    assert {:ok, [%Exograph.ReferenceHit{} = hit]} = Exograph.all(index, query)
    assert hit.reference.qualified_name == "Repo.get!/2"
    assert hit.fragment.file == path
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-reference-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
