defmodule Exograph.FragmentStore.Postgres do
  @moduledoc """
  Durable fragment store backed by Ecto and Postgres.
  """

  @behaviour Exograph.FragmentStore

  import Ecto.Query

  alias Exograph.{
    Comment,
    Definition,
    File,
    FragmentLocator,
    Package,
    PackageVersion,
    Postgres,
    Reference
  }

  alias Exograph.Extractor.Reach, as: ReachExtractor

  alias Exograph.Postgres.{
    CallEdgeRecord,
    CommentRecord,
    DefinitionRecord,
    FileRecord,
    FragmentRecord,
    GraphNodeRecord,
    Options,
    PackageRecord,
    PackageVersionRecord,
    ReferenceRecord
  }

  defstruct repo: nil,
            prefix: "exograph",
            package: nil,
            package_version: nil,
            extractors: [:ex_ast, :reach]

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          package: Package.t() | nil,
          package_version: PackageVersion.t() | nil,
          extractors: keyword() | [atom()]
        }

  @impl true
  def new(opts \\ []), do: {:ok, Options.store(__MODULE__, opts)}

  @impl true
  def put(%__MODULE__{} = store, fragments) when is_list(fragments) do
    now = DateTime.utc_now(:microsecond)

    upsert_package_context(store, now)
    files = upsert_files(store, fragments, now)

    entries =
      fragments
      |> Enum.map(fn fragment ->
        fragment
        |> FragmentRecord.from_fragment()
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)
      |> Enum.uniq_by(& &1.id)

    Postgres.bulk_insert_all(
      store.repo,
      {source(store), FragmentRecord},
      entries,
      conflict_target: [:id],
      on_conflict: :nothing,
      timeout: :infinity
    )

    upsert_code_facts(store, files, fragments, now)

    {:ok, store}
  end

  @impl true
  def get(%__MODULE__{} = store, fragment_id) do
    query =
      from(fragment in {source(store), FragmentRecord},
        left_join: file in ^files_source(store),
        on: file.id == fragment.file_id,
        where: fragment.id == ^fragment_id,
        select: {fragment, file.source, file.path}
      )

    case store.repo.one(query) do
      {%FragmentRecord{} = record, source, path} ->
        {:ok, Options.hydrate_fragment(record, source, path)}

      nil ->
        :error
    end
  end

  @impl true
  def all(%__MODULE__{} = store) do
    query =
      from(fragment in {source(store), FragmentRecord},
        left_join: file in ^files_source(store),
        on: file.id == fragment.file_id,
        order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
        select: {fragment, file.source, file.path}
      )

    store.repo.all(query)
    |> Enum.map(fn {record, source, path} -> Options.hydrate_fragment(record, source, path) end)
  end

  @impl true
  def count(%__MODULE__{} = store) do
    store.repo.aggregate({source(store), FragmentRecord}, :count)
  end

  @impl true
  def term_frequencies(_store, []), do: %{}

  def term_frequencies(%__MODULE__{} = store, terms) do
    sql = """
    SELECT term, count(*)::bigint
    FROM #{Exograph.Postgres.table(store.prefix, "fragments")}, unnest(terms) AS term
    WHERE term = ANY($1)
    GROUP BY term
    """

    store.repo
    |> Ecto.Adapters.SQL.query!(sql, [terms], timeout: :infinity)
    |> Map.fetch!(:rows)
    |> Map.new(fn [term, count] -> {term, count} end)
  end

  defp upsert_files(_store, [], _now), do: []

  defp upsert_files(store, fragments, now) do
    files =
      fragments
      |> Enum.uniq_by(& &1.file_id)
      |> Enum.reject(&is_nil(&1.file_id))
      |> Enum.map(fn fragment ->
        File.new(fragment.file, fragment.source || "", %{
          package_id: fragment.package_id,
          package_version_id: fragment.package_version_id
        })
        |> Map.put(:id, fragment.file_id)
      end)

    entries =
      Enum.map(files, fn file ->
        file
        |> FileRecord.from_file()
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    Postgres.bulk_insert_all(
      store.repo,
      files_source(store),
      entries,
      chunk_size: 2_000,
      conflict_target: [:id],
      on_conflict: :nothing,
      timeout: :infinity
    )

    files
  end

  defp upsert_code_facts(_store, [], _fragments, _now), do: :ok

  defp upsert_code_facts(store, files, fragments, now) do
    fragments_by_file = Enum.group_by(fragments, & &1.file_id)

    files_with_ast =
      Enum.map(files, fn file ->
        ast =
          case Code.string_to_quoted(file.source, line: 1, columns: true, emit_warnings: false) do
            {:ok, ast} -> ast
            _ -> nil
          end

        {file, ast}
      end)

    comments =
      files_with_ast
      |> Enum.flat_map(fn {file, _ast} ->
        file.source
        |> extract_comments()
        |> Enum.map(fn comment ->
          Comment.new(
            file,
            comment,
            FragmentLocator.containing_fragment_id(fragments_by_file[file.id], comment.line)
          )
        end)
      end)
      |> Enum.uniq_by(& &1.id)

    definitions =
      files_with_ast
      |> Enum.flat_map(fn {file, ast} ->
        symbols_from(ast, file.source, &ExAST.Symbols.definitions/1)
        |> Enum.map(fn definition ->
          Definition.new(
            file,
            definition,
            FragmentLocator.containing_fragment_id(fragments_by_file[file.id], definition.line)
          )
        end)
      end)
      |> Enum.uniq_by(& &1.id)

    references =
      files_with_ast
      |> Enum.flat_map(fn {file, ast} ->
        symbols_from(ast, file.source, &ExAST.Symbols.references/1)
        |> Enum.map(fn reference ->
          Reference.new(
            file,
            reference,
            FragmentLocator.containing_fragment_id(fragments_by_file[file.id], reference.line)
          )
        end)
      end)
      |> Enum.uniq_by(& &1.id)

    insert_code_facts(store, comments_source(store), comments, CommentRecord, :from_comment, now)

    insert_code_facts(
      store,
      definitions_source(store),
      definitions,
      DefinitionRecord,
      :from_definition,
      now
    )

    insert_code_facts(
      store,
      references_source(store),
      references,
      ReferenceRecord,
      :from_reference,
      now
    )

    if extractor_enabled?(store, :reach) do
      %{graph_nodes: graph_nodes, call_edges: call_edges} =
        ReachExtractor.extract_files(files, fragments_by_file)

      insert_code_facts(
        store,
        graph_nodes_source(store),
        graph_nodes,
        GraphNodeRecord,
        :from_graph_node,
        now
      )

      insert_code_facts(
        store,
        call_edges_source(store),
        call_edges,
        CallEdgeRecord,
        :from_call_edge,
        now
      )
    end
  end

  defp extractor_enabled?(store, name) do
    Enum.any?(store.extractors, fn
      ^name -> true
      {^name, opts} -> Keyword.get(opts, :enabled?, true)
      _other -> false
    end)
  end

  defp extract_comments(source) do
    ExAST.Comments.extract(source)
  rescue
    _ -> []
  end

  defp symbols_from(nil, source, fun) do
    fun.(source)
  rescue
    _ -> []
  end

  defp symbols_from(ast, _source, fun) do
    fun.(ast)
  rescue
    _ -> []
  end

  defp insert_code_facts(_store, _source, [], _record, _mapper, _now), do: :ok

  defp insert_code_facts(store, source, facts, record, mapper, now) do
    entries =
      Enum.map(facts, fn fact ->
        record
        |> apply(mapper, [fact])
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    Postgres.bulk_insert_all(
      store.repo,
      source,
      entries,
      chunk_size: 3_000,
      conflict_target: [:id],
      on_conflict: :nothing,
      timeout: :infinity
    )
  end

  defp upsert_package_context(%__MODULE__{package: nil, package_version: nil}, _now), do: :ok

  defp upsert_package_context(%__MODULE__{} = store, now) do
    package = store.package || package_from_version(store.package_version)

    store.repo.insert_all(
      {"#{store.prefix}_packages", PackageRecord},
      [PackageRecord.from_package(package) |> Map.merge(%{inserted_at: now, updated_at: now})],
      conflict_target: [:id],
      on_conflict: :nothing,
      timeout: :infinity
    )

    if store.package_version do
      store.repo.insert_all(
        {"#{store.prefix}_package_versions", PackageVersionRecord},
        [
          PackageVersionRecord.from_package_version(store.package_version)
          |> Map.merge(%{inserted_at: now, updated_at: now})
        ],
        conflict_target: [:id],
        on_conflict: :nothing,
        timeout: :infinity
      )
    end

    :ok
  end

  defp package_from_version(%PackageVersion{} = version) do
    %Package{
      id: version.package_id,
      ecosystem: version.ecosystem,
      name: version.package_name,
      metadata: %{}
    }
  end

  defp files_source(store), do: Options.files_source(store.prefix)
  defp comments_source(store), do: Options.comments_source(store.prefix)
  defp definitions_source(store), do: Options.definitions_source(store.prefix)
  defp references_source(store), do: Options.references_source(store.prefix)
  defp graph_nodes_source(store), do: Options.graph_nodes_source(store.prefix)
  defp call_edges_source(store), do: Options.call_edges_source(store.prefix)
  defp source(store), do: Options.fragments_source(store.prefix)
end
