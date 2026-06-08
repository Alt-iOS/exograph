defmodule Exograph.Postgres.TextSearch do
  @moduledoc false

  import Ecto.Query

  alias Exograph.Hit
  alias Exograph.Storage.Ecto.{FragmentRecord, Options}

  def search_file_field(index, literal, field, opts) when field in [:source, :comments_text] do
    file_search(
      index,
      opts,
      fn limit -> bm25_query(index, literal, field, limit, match_operator(opts)) end,
      fn limit -> ilike_query(index, literal, field, limit) end
    )
  end

  defp bm25_query(index, literal, :source, limit, :all) do
    file_to_fragment_query(
      index,
      limit,
      dynamic([file: f], fragment("?::pdb.source_code &&& ?", f.source, ^literal)),
      dynamic([file: f], fragment("pdb.score(?) DESC", f.id))
    )
  end

  defp bm25_query(index, literal, :source, limit, :any) do
    file_to_fragment_query(
      index,
      limit,
      dynamic([file: f], fragment("?::pdb.source_code ||| ?", f.source, ^literal)),
      dynamic([file: f], fragment("pdb.score(?) DESC", f.id))
    )
  end

  defp bm25_query(index, literal, :comments_text, limit, :all) do
    file_to_fragment_query(
      index,
      limit,
      dynamic([file: f], fragment("?::pdb.unicode_words &&& ?", f.comments_text, ^literal)),
      dynamic([file: f], fragment("pdb.score(?) DESC", f.id))
    )
  end

  defp bm25_query(index, literal, :comments_text, limit, :any) do
    file_to_fragment_query(
      index,
      limit,
      dynamic([file: f], fragment("?::pdb.unicode_words ||| ?", f.comments_text, ^literal)),
      dynamic([file: f], fragment("pdb.score(?) DESC", f.id))
    )
  end

  defp ilike_query(index, literal, field, limit) do
    pattern = "%#{escape_like(literal)}%"

    where_clause =
      case field do
        :source -> dynamic([file: f], ilike(f.source, ^pattern))
        :comments_text -> dynamic([file: f], ilike(f.comments_text, ^pattern))
      end

    file_to_fragment_query(index, limit, where_clause)
    |> order_by([file: f], asc: f.path)
  end

  defp file_to_fragment_query(index, limit, where_clause, order_clause \\ nil) do
    fragments_source = Options.fragments_source(index.prefix)
    files_source = Options.files_source(index.prefix)

    first_fragment =
      from(fragment in {fragments_source, FragmentRecord},
        where: fragment.file_id == parent_as(:file).id,
        order_by: [asc: fragment.line],
        limit: 1
      )

    query =
      from(file in files_source,
        as: :file,
        inner_lateral_join: fragment in subquery(first_fragment),
        on: true,
        where: ^where_clause,
        limit: ^limit,
        select: {fragment, file.source, file.path}
      )

    if order_clause, do: order_by(query, ^order_clause), else: query
  end

  defp file_search(index, opts, bm25_fun, ilike_fun) do
    limit = Keyword.get(opts, :limit, 50)

    records =
      if index.bm25? do
        try do
          bm25_fun.(limit)
          |> where_scope(opts)
          |> index.repo.all()
        rescue
          _ in [Postgrex.Error, Ecto.QueryError] ->
            ilike_records(index, ilike_fun, limit, opts)
        end
      else
        ilike_records(index, ilike_fun, limit, opts)
      end

    {:ok,
     Enum.map(records, fn {record, source, path} ->
       Hit.new(fragment: Options.hydrate_fragment(record, source, path), score: 1.0)
     end)}
  end

  defp ilike_records(index, ilike_fun, limit, opts) do
    ilike_fun.(limit)
    |> where_scope(opts)
    |> index.repo.all()
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

  defp escape_like(value), do: value |> String.replace("%", "\\%") |> String.replace("_", "\\_")

  defp match_operator(opts) do
    case Keyword.get(opts, :match, :any) do
      :all -> :all
      _other -> :any
    end
  end
end
