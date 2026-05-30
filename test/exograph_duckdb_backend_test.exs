defmodule ExographDuckDBBackendTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport

  @moduletag :integration

  test "duckdb backend indexes and searches a tiny project" do
    DuckDBSupport.start_repo!()
    prefix = "exograph_duckdb_#{System.unique_integer([:positive])}"
    opts = DuckDBSupport.opts(prefix, extractors: [:ex_ast])

    path =
      tmp_project!(%{
        "lib/demo.ex" => """
        defmodule Demo do
          def get_user(id), do: Repo.get!(User, id)
          def all_users, do: Repo.all(User)
        end
        """
      })

    assert {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))
    assert {:ok, [_hit | _]} = Exograph.search(index, "Repo.get!(_, _)")
    assert [_fragment | _] = Exograph.Postgres.FragmentStore.all(index.fragment_store)
  end

  defp tmp_project!(files) do
    root = Path.join(System.tmp_dir!(), "exograph-duckdb-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)

    Enum.each(files, fn {relative, contents} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    root
  end
end
