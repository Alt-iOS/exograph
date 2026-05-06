defmodule ExographBackendTest do
  use ExUnit.Case, async: false

  test "index handle separates inverted index, fragment store, and tree store" do
    path =
      fixture("tree.ex", """
      defmodule Demo.Tree do
        @doc "hello"
        def first_fun do
          :ok
        end
      end
      """)

    {:ok, index} = Exograph.index(path, min_mass: 4)
    [%{fragment: fragment}] = elem(Exograph.search(index, "def first_fun do ... end"), 1)

    assert {:ok, ^fragment} = index.fragment_store_backend.get(index.fragment_store, fragment.id)
    assert [_ | _] = Exograph.tree_nodes(index, fragment.id)
    fragments = index.fragment_store_backend.all(index.fragment_store)
    assert Enum.any?(fragments, &("attribute:doc" in &1.terms))
    assert "first_fun/0" in fragment.defs
  end

  test "explains compiled query plans" do
    explanation = Exograph.explain("Repo.get!(User, id)")

    assert "call.remote:Repo.get!/2" in explanation.required
    assert explanation.verifier == :pattern
  end

  test "finds structurally similar fragments" do
    path =
      fixture("similar.ex", """
      defmodule Demo.Similar do
        def one(user, attrs) do
          user
          |> cast(attrs, [:name])
          |> validate_required([:name])
        end

        def two(account, params) do
          account
          |> cast(params, [:name])
          |> validate_required([:name])
        end
      end
      """)

    {:ok, index} = Exograph.index(path, min_mass: 4)

    {:ok, results} =
      Exograph.similar(
        index,
        """
        user
        |> cast(attrs, [:name])
        |> validate_required([:name])
        """,
        min_similarity: 0.7
      )

    assert Enum.any?(results, &(&1.similarity >= 0.7))
  end

  test "literal and regex text search use fragment verification" do
    path =
      fixture("text.ex", """
      defmodule Demo.TextSearch do
        def route, do: ~p"/users/:id"
      end
      """)

    {:ok, index} = Exograph.index(path, min_mass: 4)

    assert {:ok, [%{fragment: %{file: ^path}} | _]} = Exograph.search_text(index, "/users/:id")

    assert {:ok, [%{fragment: %{file: ^path}} | _]} =
             Exograph.search_text(index, ~r/users\/:[a-z]+/)
  end

  test "backend profiles wire stores from one high-level option" do
    path =
      fixture("profile.ex", """
      defmodule Demo.Profile do
        def get_user(id), do: Repo.get!(User, id)
      end
      """)

    {:ok, index} = Exograph.index(path, backend: :memory, min_mass: 4)

    assert index.inverted_backend == Exograph.InvertedIndex.Memory
    assert index.fragment_store_backend == Exograph.FragmentStore.Memory
    assert index.tree_store_backend == Exograph.TreeStore.Memory
    assert {:ok, [_ | _]} = Exograph.search(index, "Repo.get!(_, _)")
  end

  test "TantivyEx backend retrieves candidate fragments" do
    path =
      fixture("tantivy.ex", """
      defmodule Demo.Tantivy do
        def get_user(id) do
          Repo.get!(User, id)
        end
      end
      """)

    index_path =
      Path.join(System.tmp_dir!(), "exograph-tantivy-#{System.unique_integer([:positive])}")

    {:ok, index} =
      Exograph.index(path,
        min_mass: 4,
        backend: Exograph.InvertedIndex.TantivyEx,
        backend_opts: [path: index_path]
      )

    {:ok, results} = Exograph.search(index, "Repo.get!(_, _)")

    assert [%{fragment: %{file: ^path}} | _] = results
  end

  defp fixture(name, source) do
    dir = Path.join(System.tmp_dir!(), "exograph-tests-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
