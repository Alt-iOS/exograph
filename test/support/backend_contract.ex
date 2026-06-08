defmodule Exograph.BackendContract do
  @moduledoc false

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]

  alias Exograph.Storage.Ecto.FragmentStore, as: EctoFragmentStore
  alias Exograph.Storage.Ecto.{PackageRecord, PackageVersionRecord}

  def assert_real_indexing_and_search(opts) do
    path = fixture(opts)
    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    assert_fragments(index, path)
    assert_package_scope(index, opts)
    assert_structural_search(index, path)
    assert_selector_search(index, path)
    assert_capture_guard_search(index, path)
    assert_comment_search(index, path)
    assert_text_search(index, path)
    assert_reference_search(index, path)
    assert_call_graph_search(index)
    assert_similarity(index, path)
  end

  def start_postgres_repo(url) do
    case Exograph.TestRepo.start_link(
           url: url,
           pool_size: 2,
           ssl: false,
           stacktrace: true,
           show_sensitive_data_on_connection_error: true,
           log: false
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  def postgres_available?(url) when is_binary(url) do
    case start_postgres_repo(url) do
      {:ok, pid} ->
        Process.exit(pid, :normal)
        true

      {:error, _reason} ->
        false
    end
  end

  def postgres_available?(_url), do: false

  def assert_postgres_package_rows(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.fetch!(opts, :prefix)
    version_attrs = Keyword.fetch!(opts, :package_version)
    ecosystem = to_string(Keyword.get(version_attrs, :ecosystem, :hex))
    package_name = Keyword.get(version_attrs, :name)
    version_str = Keyword.get(version_attrs, :version, "1.0.0")

    packages = {"#{prefix}_packages", PackageRecord}
    package_versions = {"#{prefix}_package_versions", PackageVersionRecord}

    package_query =
      from(package in packages,
        where: package.ecosystem == ^ecosystem and package.name == ^package_name
      )

    package_id =
      repo.one!(
        from(p in packages,
          where: p.ecosystem == ^ecosystem and p.name == ^package_name,
          select: p.id
        )
      )

    package_version_query =
      from(package_version in package_versions,
        where:
          package_version.package_id == ^package_id and
            package_version.version == ^version_str
      )

    assert repo.aggregate(package_query, :count) == 1
    assert repo.aggregate(package_version_query, :count) == 1
  end

  def assert_postgres_code_fact_rows(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.fetch!(opts, :prefix)

    assert count_rows(repo, prefix, "comments") >= 1
    assert count_rows(repo, prefix, "definitions") >= 1
    assert count_rows(repo, prefix, "references") >= 1
    assert count_rows(repo, prefix, "graph_nodes") >= 1
    assert count_rows(repo, prefix, "call_edges") >= 1

    assert count_rows(repo, prefix, "definitions", "qualified_name LIKE '%.get_user/1'") == 1
    assert count_rows(repo, prefix, "references", "qualified_name = 'Repo.transaction/1'") >= 1

    assert count_rows(repo, prefix, "call_edges", "callee_qualified_name = 'Repo.transaction/1'") >=
             1
  end

  defp count_rows(repo, prefix, table, where \\ "true") do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT count(*)::bigint FROM #{Exograph.Storage.Ecto.SQL.table(prefix, table)} WHERE #{where}",
        []
      )

    count
  end

  def drop_postgres_prefix(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.fetch!(opts, :prefix)

    for table <- [
          "tree_nodes",
          "call_edges",
          "graph_nodes",
          "references",
          "definitions",
          "comments",
          "fragments",
          "fragment_terms",
          "terms",
          "files",
          "package_versions",
          "packages",
          "schema_migrations"
        ] do
      Ecto.Adapters.SQL.query!(
        repo,
        "DROP TABLE IF EXISTS #{Exograph.Storage.Ecto.SQL.table(prefix, table)} CASCADE",
        []
      )
    end

    :ok
  end

  defp assert_fragments(index, path) do
    assert [_ | _] = fragments = EctoFragmentStore.all(index.fragment_store)
    assert Enum.any?(fragments, &(&1.file == path and &1.name == "get_user"))
    assert Enum.any?(fragments, &(&1.file == path and &1.name == "update_user"))
  end

  defp assert_package_scope(index, _opts) do
    all_fragments = EctoFragmentStore.all(index.fragment_store)

    assert Enum.all?(all_fragments, fn fragment ->
             is_integer(fragment.package_id) and is_integer(fragment.package_version_id)
           end)

    package_version_id = hd(all_fragments).package_version_id

    assert {:ok, [_ | _]} =
             Exograph.search(index, "Repo.get!(_, _)", package_version_id: package_version_id)

    assert {:ok, []} =
             Exograph.search(index, "Repo.get!(_, _)", package_version_id: -1)
  end

  defp assert_structural_search(index, path) do
    assert {:ok, [%Exograph.Hit{fragment: fragment} | _]} =
             Exograph.search(index, "Repo.get!(_, _)")

    assert fragment.file == path
    assert {:ok, ^fragment} = EctoFragmentStore.get(index.fragment_store, fragment.id)

    tree_fragment =
      EctoFragmentStore.all(index.fragment_store)
      |> Enum.find(
        &(&1.file == path and &1.kind in [:module, :def, :defp, :defmacro, :defmacrop])
      )

    assert tree_fragment
    assert [_ | _] = Exograph.tree_nodes(index, tree_fragment.id)
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

  defp assert_capture_guard_search(index, path) do
    import ExAST.Query

    query = from("left == right") |> where(^left == ^right)

    assert {:ok, results} = Exograph.search(index, query)

    assert Enum.any?(results, fn result ->
             result.fragment.file == path and Macro.to_string(result.match.node) == "same == same"
           end)

    refute Enum.any?(results, fn result ->
             result.fragment.file == path and
               Macro.to_string(result.match.node) == "left == right"
           end)
  end

  defp assert_comment_search(index, path) do
    import ExAST.Query

    query = from("def _ do ... end") |> where(comment_before(text("transaction wrapper")))

    assert {:ok, results} = Exograph.search(index, query)

    assert Enum.any?(results, fn result ->
             result.fragment.file == path and Macro.to_string(result.match.node) =~ "update_user"
           end)
  end

  defp assert_text_search(index, path) do
    assert {:ok, [%{fragment: text_fragment} | _]} = Exograph.search_text(index, "Repo.get!")
    assert text_fragment.file == path
  end

  defp assert_reference_search(index, path) do
    assert {:ok, [%{fragment: reference_fragment} | _]} =
             Exograph.search_references(index, "Repo.transaction")

    assert reference_fragment.file == path
  end

  defp assert_call_graph_search(index) do
    assert {:ok, [edge | _]} = Exograph.search_callers(index, "Repo.transaction/1")
    assert edge.callee_qualified_name == "Repo.transaction/1"
    assert edge.caller_qualified_name =~ ".update_user/2"

    assert {:ok, [edge | _]} = Exograph.search_callees(index, edge.caller_qualified_name)
    assert edge.callee_qualified_name == "Repo.transaction/1"
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

  defp fixture(_opts) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-postgres-contract-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "postgres.ex")
    File.write!(path, source(Demo.BackendContract.Postgres))
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

        def compare_same(same) do
          same == same
        end

        def compare_different(left, right) do
          left == right
        end

        def update_account(account, params) do
          account
          |> cast(params, [:name])
          |> validate_required([:name])
        end
      end
    end
    |> Macro.to_string()
    |> String.replace("def update_user", "# transaction wrapper\n  def update_user")
  end
end
