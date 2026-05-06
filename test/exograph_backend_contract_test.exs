defmodule ExographBackendContractTest.BackendContract do
  @moduledoc false

  import ExUnit.Assertions

  def assert_profile(profile, expected) do
    config = Exograph.Backend.config(profile.opts)

    assert Keyword.fetch!(config, :inverted) == expected.inverted
    assert Keyword.fetch!(config, :fragment_store) == expected.fragment_store
    assert Keyword.fetch!(config, :tree_store) == expected.tree_store

    assert Keyword.keyword?(Keyword.fetch!(config, :inverted_opts))
    assert Keyword.keyword?(Keyword.fetch!(config, :fragment_store_opts))
    assert Keyword.keyword?(Keyword.fetch!(config, :tree_store_opts))
  end

  def assert_index_contract(profile) do
    path = fixture("#{profile.name}.ex", source(profile.module))
    {:ok, index} = Exograph.index(path, Keyword.merge(profile.opts, min_mass: 4))

    assert [_ | _] = fragments = index.fragment_store_backend.all(index.fragment_store)
    assert Enum.any?(fragments, &(&1.name == "get_user"))

    assert {:ok, [%{fragment: fragment} | _]} = Exograph.search(index, "Repo.get!(_, _)")
    assert fragment.file == path
    assert {:ok, ^fragment} = index.fragment_store_backend.get(index.fragment_store, fragment.id)
    assert [_ | _] = Exograph.tree_nodes(index, fragment.id)

    assert {:ok, [%{fragment: text_fragment} | _]} = Exograph.search_text(index, "Repo.get!")
    assert text_fragment.file == path
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-backend-contract-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end

  defp source(module) do
    quote do
      defmodule unquote(module) do
        def get_user(id) do
          Repo.get!(User, id)
        end

        def list_users do
          Repo.all(User)
        end
      end
    end
    |> Macro.to_string()
  end
end

defmodule ExographBackendContractTest do
  use ExUnit.Case, async: false

  alias ExographBackendContractTest.BackendContract

  @profiles [
    %{
      name: :memory,
      module: Demo.BackendContract.Memory,
      opts: [backend: :memory],
      expected: %{
        inverted: Exograph.InvertedIndex.Memory,
        fragment_store: Exograph.FragmentStore.Memory,
        tree_store: Exograph.TreeStore.Memory
      },
      runnable?: true
    },
    %{
      name: :tantivy,
      module: Demo.BackendContract.Tantivy,
      opts: [
        backend: :tantivy,
        index_path:
          Path.join(
            System.tmp_dir!(),
            "exograph-contract-tantivy-#{System.unique_integer([:positive])}"
          )
      ],
      expected: %{
        inverted: Exograph.InvertedIndex.TantivyEx,
        fragment_store: Exograph.FragmentStore.Memory,
        tree_store: Exograph.TreeStore.Memory
      },
      runnable?: true
    },
    %{
      name: :postgres,
      module: Demo.BackendContract.Postgres,
      opts: [backend: :postgres, repo: Demo.Repo, migrate?: true],
      expected: %{
        inverted: Exograph.InvertedIndex.Postgres,
        fragment_store: Exograph.FragmentStore.Postgres,
        tree_store: Exograph.TreeStore.Postgres
      },
      runnable?: false
    }
  ]

  for profile <- @profiles do
    @profile profile

    test "#{profile.name} backend profile wires expected behaviour modules" do
      BackendContract.assert_profile(@profile, @profile.expected)
    end
  end

  for profile <- Enum.filter(@profiles, & &1.runnable?) do
    @profile profile

    test "#{profile.name} backend satisfies index/search/text/tree contract" do
      BackendContract.assert_index_contract(@profile)
    end
  end
end
