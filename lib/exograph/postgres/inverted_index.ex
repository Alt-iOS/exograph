defmodule Exograph.Postgres.InvertedIndex do
  @moduledoc """
  Postgres/ParadeDB candidate retrieval backend implemented with Ecto queries.

  Structural lookups use the `terms integer[]` GIN index. Term strings are
  normalized to integer IDs in the terms table before querying.
  """

  import Ecto.Query

  alias Exograph.{Hit, Package, PackageVersion}
  alias Exograph.Postgres.{CallEdgeRecord, FactQuery, FragmentRecord, Options}
  alias Exograph.StructuralQuery

  defstruct repo: nil, prefix: "exograph", package: nil, package_version: nil

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          package: Package.t() | nil,
          package_version: PackageVersion.t() | nil
        }

  def new(opts \\ []), do: {:ok, Options.store(__MODULE__, opts)}

  def add(%__MODULE__{} = index, fragments) when is_list(fragments) do
    {:ok, index}
  end

  def search(%__MODULE__{} = index, %StructuralQuery{} = query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    required = MapSet.to_list(query.required_terms)
    optional = MapSet.to_list(query.optional_terms)

    required_ids = resolve_term_ids(index, required)
    optional_ids = resolve_term_ids(index, optional)

    required_id_set = MapSet.new(required_ids)
    optional_id_set = MapSet.new(optional_ids)

    records =
      base_query(index)
      |> where_term_ids(required_ids, optional_ids)
      |> where_scope(opts)
      |> limit(^limit)
      |> with_file(index, include_source?(query))
      |> index.repo.all()

    hits = Enum.map(records, &hit(&1, query, required_id_set, optional_id_set))
    {:ok, hits}
  end

  def search_text(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    search_file_field(index, literal, :source, opts)
  end

  def search_comments(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    search_file_field(index, literal, :comments_text, opts)
  end

  def search_definitions(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    FactQuery.search(index, definitions_source(index), literal, opts)
  end

  def search_references(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    FactQuery.search(index, references_source(index), literal, opts)
  end

  def search_callers(%__MODULE__{} = index, callee, opts \\ []) when is_binary(callee) do
    search_call_edges(index, :callee_qualified_name, callee, opts)
  end

  def search_callees(%__MODULE__{} = index, caller, opts \\ []) when is_binary(caller) do
    search_call_edges(index, :caller_qualified_name, caller, opts)
  end

  defp search_call_edges(index, field, literal, opts) do
    limit = Keyword.get(opts, :limit, 50)

    records =
      from(edge in call_edges_source(index),
        where: field(edge, ^field) == ^literal or ilike(field(edge, ^field), ^"%#{literal}%"),
        order_by: [asc: edge.file_id, asc: edge.line, asc: edge.id],
        limit: ^limit
      )
      |> where_scope(opts)
      |> index.repo.all()

    {:ok, Enum.map(records, &CallEdgeRecord.to_call_edge/1)}
  end

  def resolve_term_ids(_index, []), do: []

  def resolve_term_ids(index, terms) when is_list(terms) do
    from(t in Options.terms_source(index.prefix), where: t.term in ^terms, select: t.id)
    |> index.repo.all(timeout: :infinity)
  rescue
    _ -> []
  end

  defp include_source?(%StructuralQuery{verifier: {:selector, _selector}} = query),
    do: StructuralQuery.requires_source?(query)

  defp include_source?(_query), do: true

  defp search_file_field(index, literal, :source, opts) do
    file_search(index, literal, opts, fn files_source, limit ->
      source_search_query(index, files_source, literal, limit, match_operator(opts))
    end)
  end

  defp search_file_field(index, literal, :comments_text, opts) do
    file_search(index, literal, opts, fn files_source, limit ->
      comments_search_query(index, files_source, literal, limit, match_operator(opts))
    end)
  end

  defp source_search_query(index, files_source, literal, limit, :all) do
    from(fragment in {source(index), FragmentRecord},
      join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment("?::pdb.source_code &&& ?", file.source, ^literal),
      order_by: [desc: fragment("pdb.score(?)", file.id)],
      limit: ^limit,
      select: {fragment, file.source, file.path}
    )
  end

  defp source_search_query(index, files_source, literal, limit, :any) do
    from(fragment in {source(index), FragmentRecord},
      join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment("?::pdb.source_code ||| ?", file.source, ^literal),
      order_by: [desc: fragment("pdb.score(?)", file.id)],
      limit: ^limit,
      select: {fragment, file.source, file.path}
    )
  end

  defp comments_search_query(index, files_source, literal, limit, :all) do
    from(fragment in {source(index), FragmentRecord},
      join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment("?::pdb.unicode_words &&& ?", file.comments_text, ^literal),
      order_by: [desc: fragment("pdb.score(?)", file.id)],
      limit: ^limit,
      select: {fragment, file.source, file.path}
    )
  end

  defp comments_search_query(index, files_source, literal, limit, :any) do
    from(fragment in {source(index), FragmentRecord},
      join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment("?::pdb.unicode_words ||| ?", file.comments_text, ^literal),
      order_by: [desc: fragment("pdb.score(?)", file.id)],
      limit: ^limit,
      select: {fragment, file.source, file.path}
    )
  end

  defp match_operator(opts) do
    case Keyword.get(opts, :match, :any) do
      :all -> :all
      _other -> :any
    end
  end

  defp file_search(index, _literal, opts, query_fun) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      index
      |> files_source()
      |> query_fun.(limit)
      |> where_scope(opts)

    hits =
      index.repo.all(query)
      |> Enum.map(fn {record, source, path} ->
        Hit.new(fragment: Options.hydrate_fragment(record, source, path), score: 1.0)
      end)

    {:ok, hits}
  rescue
    exception in [Postgrex.Error, Ecto.QueryError] -> {:error, exception}
  end

  defp with_file(queryable, index, true) do
    from(fragment in queryable,
      left_join: file in ^files_source(index),
      on: file.id == fragment.file_id,
      select: {fragment, file.source, file.path}
    )
  end

  defp with_file(queryable, index, false) do
    from(fragment in queryable,
      left_join: file in ^files_source(index),
      on: file.id == fragment.file_id,
      select: {fragment, nil, file.path}
    )
  end

  defp base_query(index) do
    from(fragment in {source(index), FragmentRecord},
      order_by: [desc: fragment.mass, asc: fragment.file_id, asc: fragment.line]
    )
  end

  defp where_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)
    package_version_id = Keyword.get(opts, :package_version_id)
    package_version = Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_package(package_id)
    |> maybe_where_package_version(package_version_id || package_version)
  end

  defp maybe_where_package(queryable, nil), do: queryable

  defp maybe_where_package(queryable, package_id),
    do: where(queryable, [fragment], fragment.package_id == ^package_id)

  defp maybe_where_package_version(queryable, nil), do: queryable

  defp maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [fragment], fragment.package_version_id == ^package_version_id)

  defp where_term_ids(queryable, [], []), do: queryable

  defp where_term_ids(queryable, required_ids, []) when required_ids != [] do
    where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^required_ids))
  end

  defp where_term_ids(queryable, [], optional_ids) when optional_ids != [] do
    where(queryable, [fragment], fragment("? && ?", fragment.terms, ^optional_ids))
  end

  defp where_term_ids(queryable, required_ids, _optional_ids) do
    where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^required_ids))
  end

  defp hit({%FragmentRecord{} = record, source, path}, _query, required_id_set, optional_id_set) do
    fragment = Options.hydrate_fragment(record, source, path)
    required_matches = MapSet.intersection(fragment.terms, required_id_set)
    optional_matches = MapSet.intersection(fragment.terms, optional_id_set)

    Hit.new(
      fragment: fragment,
      score: MapSet.size(required_matches) * 10 + MapSet.size(optional_matches),
      matched_terms: required_matches |> MapSet.union(optional_matches) |> MapSet.to_list()
    )
  end

  defp files_source(index), do: Options.files_source(index.prefix)
  defp definitions_source(index), do: Options.definitions_source(index.prefix)
  defp references_source(index), do: Options.references_source(index.prefix)
  defp call_edges_source(index), do: Options.call_edges_source(index.prefix)
  defp source(index), do: Options.fragments_source(index.prefix)
end
