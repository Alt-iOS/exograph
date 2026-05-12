defmodule ExographBackendTest do
  use ExUnit.Case, async: false

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_backend_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "index handle uses Postgres stores", %{opts: opts} do
    path =
      fixture("tree.ex", """
      defmodule Demo.Tree do
        @doc "hello"
        def first_fun do
          :ok
        end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    [%Exograph.Hit{fragment: fragment}] =
      elem(Exograph.search(index, "def first_fun do ... end"), 1)

    assert index.inverted_backend == Exograph.InvertedIndex.Postgres
    assert index.fragment_store_backend == Exograph.FragmentStore.Postgres
    assert index.tree_store_backend == Exograph.TreeStore.Postgres
    assert {:ok, ^fragment} = index.fragment_store_backend.get(index.fragment_store, fragment.id)
    assert [_ | _] = Exograph.tree_nodes(index, fragment.id)
    fragments = index.fragment_store_backend.all(index.fragment_store)
    assert Enum.any?(fragments, &(MapSet.size(&1.terms) > 0))
  end

  test "finds structurally similar fragments", %{opts: opts} do
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

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

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

  test "can disable Reach semantic extraction", %{opts: opts} do
    path =
      fixture("without_reach.ex", """
      defmodule Demo.WithoutReach do
        def update_user(user), do: Repo.transaction(fn -> user end)
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4, extractors: [:ex_ast]))

    assert {:ok, []} = Exograph.search_callers(index, "Repo.transaction/1")
  end

  test "literal and regex text search use fragment verification", %{opts: opts} do
    path =
      fixture("text.ex", """
      defmodule Demo.TextSearch do
        def route, do: ~p"/users/:id"
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    assert {:ok, [%Exograph.TextHit{fragment: %{file: ^path}} | _]} =
             Exograph.search_text(index, "/users/:id")

    assert {:ok, [%Exograph.TextHit{fragment: %{file: ^path}} | _]} =
             Exograph.search_text(index, ~r/users\/:[a-z]+/)
  end

  defp fixture(name, source) do
    dir = Path.join(System.tmp_dir!(), "exograph-tests-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
