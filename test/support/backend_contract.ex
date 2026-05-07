defmodule Exograph.BackendContract do
  @moduledoc false

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]

  alias Exograph.Postgres.{PackageRecord, PackageVersionRecord}

  def assert_real_indexing_and_search(opts) do
    path = fixture(opts)
    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    assert_postgres_modules(index)
    assert_fragments(index, path)
    assert_package_scope(index, opts)
    assert_structural_search(index, path)
    assert_selector_search(index, path)
    assert_capture_guard_search(index, path)
    assert_comment_search(index, path)
    assert_text_search(index, path)
    assert_reference_search(index, path)
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

      {:error, {:already_started, _pid}} ->
        true

      {:error, _reason} ->
        false
    end
  end

  def postgres_available?(_url), do: false

  def assert_postgres_package_rows(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.fetch!(opts, :prefix)
    version = Exograph.PackageVersion.new(Keyword.fetch!(opts, :package_version))

    packages = {"#{prefix}_packages", PackageRecord}
    package_versions = {"#{prefix}_package_versions", PackageVersionRecord}

    package_query = from(package in packages, where: package.id == ^version.package_id)

    package_version_query =
      from(package_version in package_versions,
        where:
          package_version.id == ^version.id and package_version.package_id == ^version.package_id
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

    assert count_rows(repo, prefix, "definitions", "qualified_name LIKE '%.get_user/1'") == 1
    assert count_rows(repo, prefix, "references", "qualified_name = 'Repo.transaction/1'") >= 1
  end

  defp count_rows(repo, prefix, table, where \\ "true") do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT count(*)::bigint FROM #{Exograph.Postgres.table(prefix, table)} WHERE #{where}",
        []
      )

    count
  end

  def drop_postgres_prefix(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.fetch!(opts, :prefix)

    for table <- [
          "tree_nodes",
          "references",
          "definitions",
          "comments",
          "fragments",
          "files",
          "package_versions",
          "packages",
          "schema_migrations"
        ] do
      Ecto.Adapters.SQL.query!(
        repo,
        "DROP TABLE IF EXISTS #{Exograph.Postgres.table(prefix, table)} CASCADE",
        []
      )
    end

    :ok
  end

  defp assert_postgres_modules(index) do
    assert index.inverted_backend == Exograph.InvertedIndex.Postgres
    assert index.fragment_store_backend == Exograph.FragmentStore.Postgres
    assert index.tree_store_backend == Exograph.TreeStore.Postgres
  end

  defp assert_fragments(index, path) do
    assert [_ | _] = fragments = index.fragment_store_backend.all(index.fragment_store)
    assert Enum.any?(fragments, &(&1.file == path and &1.name == "get_user"))
    assert Enum.any?(fragments, &(&1.file == path and &1.name == "update_user"))
  end

  defp assert_package_scope(index, opts) do
    package_version = Exograph.PackageVersion.new(Keyword.fetch!(opts, :package_version))

    assert Enum.all?(index.fragment_store_backend.all(index.fragment_store), fn fragment ->
             fragment.package_id == package_version.package_id and
               fragment.package_version_id == package_version.id
           end)

    assert {:ok, [_ | _]} =
             Exograph.search(index, "Repo.get!(_, _)", package_version_id: package_version.id)

    assert {:ok, []} =
             Exograph.search(index, "Repo.get!(_, _)", package_version_id: "hex:other@0.1.0")
  end

  defp assert_structural_search(index, path) do
    assert {:ok, [%{fragment: fragment} | _]} = Exograph.search(index, "Repo.get!(_, _)")
    assert fragment.file == path
    assert {:ok, ^fragment} = index.fragment_store_backend.get(index.fragment_store, fragment.id)

    tree_fragment =
      index.fragment_store_backend.all(index.fragment_store)
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
