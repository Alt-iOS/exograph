defmodule Exograph.InvertedIndex.Postgres do
  @moduledoc """
  Postgres/ParadeDB candidate retrieval backend implemented with Ecto queries.

  Structural lookups use the `terms text[]` GIN index. Text relevance fields are
  stored alongside the same rows so deployments with `pg_search` can add a BM25
  index without changing Exograph's logical verification pipeline.
  """

  @behaviour Exograph.InvertedIndex

  import Ecto.Query

  alias Exograph.{Hit, Package, PackageVersion}
  alias Exograph.Postgres.{FragmentRecord, Options}
  alias Exograph.Query, as: ExographQuery

  defstruct repo: nil, prefix: "exograph", package: nil, package_version: nil

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          package: Package.t() | nil,
          package_version: PackageVersion.t() | nil
        }

  @impl true
  def new(opts \\ []), do: {:ok, Options.store(__MODULE__, opts)}

  @impl true
  def add(%__MODULE__{} = index, fragments) when is_list(fragments) do
    {:ok, index}
  end

  @impl true
  def search(%__MODULE__{} = index, %ExographQuery{} = query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    required = MapSet.to_list(query.required_terms)
    optional = MapSet.to_list(query.optional_terms)

    records =
      base_query(index)
      |> where_terms(required, optional)
      |> where_scope(opts)
      |> limit(^limit)
      |> with_file(index, include_source?(query))
      |> index.repo.all()

    hits = Enum.map(records, &hit(&1, query))
    {:ok, hits}
  end

  def search_text(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    search_file_field(index, literal, :source, opts)
  end

  def search_comments(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    search_file_field(index, literal, :comments_text, opts)
  end

  def search_definitions(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(fragment in {source(index), FragmentRecord},
        where: fragment.kind in [:def, :defp, :defmacro, :defmacrop],
        where:
          fragment(
            "?::pdb.edge_ngram(2, 32, 'token_chars=letter,digit,punctuation') ||| ?",
            fragment.name,
            ^literal
          ),
        order_by: [desc: fragment("paradedb.score(?)", fragment.id)],
        limit: ^limit,
        select: {fragment, nil, nil}
      )
      |> where_scope(opts)
      |> with_path(index)

    hits =
      index.repo.all(query)
      |> Enum.map(fn {record, path} ->
        Hit.new(fragment: Options.hydrate_fragment(record, nil, path), score: 1.0)
      end)

    {:ok, hits}
  rescue
    exception in [Postgrex.Error, Ecto.QueryError] -> {:error, exception}
  end

  defp include_source?(%ExographQuery{verifier: {:selector, _selector}} = query),
    do: ExographQuery.requires_source?(query)

  defp include_source?(_query), do: true

  defp search_file_field(index, literal, :source, opts) do
    file_search(index, literal, opts, fn files_source, limit ->
      from(fragment in {source(index), FragmentRecord},
        join: file in ^files_source,
        on: file.id == fragment.file_id,
        where: fragment("?::pdb.source_code ||| ?", file.source, ^literal),
        order_by: [desc: fragment("paradedb.score(?)", file.id)],
        limit: ^limit,
        select: {fragment, file.source, file.path}
      )
    end)
  end

  defp search_file_field(index, literal, :comments_text, opts) do
    file_search(index, literal, opts, fn files_source, limit ->
      from(fragment in {source(index), FragmentRecord},
        join: file in ^files_source,
        on: file.id == fragment.file_id,
        where: fragment("?::pdb.unicode ||| ?", file.comments_text, ^literal),
        order_by: [desc: fragment("paradedb.score(?)", file.id)],
        limit: ^limit,
        select: {fragment, file.source, file.path}
      )
    end)
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

  defp with_path(queryable, index) do
    from(fragment in queryable,
      left_join: file in ^files_source(index),
      on: file.id == fragment.file_id,
      select: {fragment, file.path}
    )
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

  defp where_terms(queryable, [], []), do: queryable

  defp where_terms(queryable, required, []) do
    where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^required))
  end

  defp where_terms(queryable, [], optional) do
    where(queryable, [fragment], fragment("? && ?", fragment.terms, ^optional))
  end

  defp where_terms(queryable, required, _optional) do
    where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^required))
  end

  defp hit({%FragmentRecord{} = record, source, path}, query) do
    fragment = Options.hydrate_fragment(record, source, path)
    required_matches = MapSet.intersection(fragment.terms, query.required_terms)
    optional_matches = MapSet.intersection(fragment.terms, query.optional_terms)

    Hit.new(
      fragment: fragment,
      score: MapSet.size(required_matches) * 10 + MapSet.size(optional_matches),
      matched_terms: required_matches |> MapSet.union(optional_matches) |> MapSet.to_list()
    )
  end

  defp files_source(index), do: Options.files_source(index.prefix)
  defp source(index), do: Options.fragments_source(index.prefix)
end
