defmodule Exograph.BackendContract do
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

  def assert_real_indexing_and_search(profile) do
    path = fixture(profile)
    {:ok, index} = Exograph.index(path, Keyword.merge(profile.opts, min_mass: 4))

    assert_profile_modules(index, profile.expected)
    assert_fragments(index, path)
    assert_structural_search(index, path)
    assert_selector_search(index, path)
    assert_text_search(index, path)
    assert_similarity(index, path)
  end

  def start_postgres_repo(url) do
    Exograph.TestRepo.start_link(
      url: url,
      pool_size: 2,
      ssl: false,
      stacktrace: true,
      show_sensitive_data_on_connection_error: true
    )
  end

  def postgres_available?(url) when is_binary(url) do
    case start_postgres_repo(url) do
      {:ok, pid} ->
        Process.exit(pid, :normal)
        true

      {:error, {:already_started, _pid}} ->
        true

      {:error, _reason} ->
        false
    end
  end

  def postgres_available?(_url), do: false

  defp assert_profile_modules(index, expected) do
    assert index.inverted_backend == expected.inverted
    assert index.fragment_store_backend == expected.fragment_store
    assert index.tree_store_backend == expected.tree_store
  end

  defp assert_fragments(index, path) do
    assert [_ | _] = fragments = index.fragment_store_backend.all(index.fragment_store)
    assert Enum.any?(fragments, &(&1.file == path and &1.name == "get_user"))
    assert Enum.any?(fragments, &(&1.file == path and &1.name == "update_user"))
  end

  defp assert_structural_search(index, path) do
    assert {:ok, [%{fragment: fragment} | _]} = Exograph.search(index, "Repo.get!(_, _)")
    assert fragment.file == path
    assert {:ok, ^fragment} = index.fragment_store_backend.get(index.fragment_store, fragment.id)
    assert [_ | _] = Exograph.tree_nodes(index, fragment.id)
  end

  defp assert_selector_search(index, path) do
    import ExAST.Query

    query =
      from("def _ do ... end")
      |> where(contains("Repo.transaction(_)"))

    assert {:ok, results} = Exograph.search(index, query)

    assert Enum.any?(results, fn result ->
             result.fragment.file == path and Macro.to_string(result.match.node) =~ "update_user"
           end)
  end

  defp assert_text_search(index, path) do
    assert {:ok, [%{fragment: text_fragment} | _]} = Exograph.search_text(index, "Repo.get!")
    assert text_fragment.file == path
  end

  defp assert_similarity(index, path) do
    {:ok, results} =
      Exograph.similar(
        index,
        quote do
          user
          |> cast(attrs, [:name])
          |> validate_required([:name])
        end,
        min_similarity: 0.7
      )

    assert Enum.any?(results, &(&1.fragment.file == path and &1.similarity >= 0.7))
  end

  defp fixture(profile) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-backend-contract-#{profile.name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{profile.name}.ex")
    File.write!(path, source(profile.module))
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

        def update_user(user, attrs) do
          Repo.transaction(fn ->
            user
            |> cast(attrs, [:name])
            |> validate_required([:name])
            |> Repo.update!()
          end)
        end

        def update_account(account, params) do
          account
          |> cast(params, [:name])
          |> validate_required([:name])
        end
      end
    end
    |> Macro.to_string()
  end
end
