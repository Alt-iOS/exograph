defmodule Exograph.CodeFactQuery do
  @moduledoc false

  import Ecto.Query

  alias Exograph.{Hit, Scope, Text}
  alias Exograph.Postgres.{FragmentRecord, Options}

  def search(index, table_source, literal, opts) do
    limit = Keyword.get(opts, :limit, 50)
    files_source = Options.files_source(index.prefix)

    query =
      from(fragment in {Options.fragments_source(index.prefix), FragmentRecord},
        join: fact in ^table_source,
        on: fact.fragment_id == fragment.id,
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        where: ^fact_filter(literal),
        order_by: [desc: fragment("pdb.score(?)", fact.id)],
        limit: ^limit,
        select: {fragment, nil, file.path}
      )
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

  def where_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_package(package_id)
    |> maybe_where_package_version(package_version_id)
  end

  def fallback_filter(fragments, literal, opts, mapper) do
    literal = String.downcase(literal)

    fragments
    |> Enum.filter(fn fragment ->
      Scope.fragment?(fragment, opts) and Enum.any?(mapper.(fragment), &contains?(&1, literal))
    end)
  end

  defp fact_filter(literal) do
    dynamic(
      [_fragment, fact],
      fragment(
        "?::pdb.edge_ngram(2, 96, 'token_chars=letter,digit,punctuation') ||| ?",
        fact.qualified_name,
        ^literal
      ) or
        fragment(
          "?::pdb.edge_ngram(2, 32, 'token_chars=letter,digit,punctuation') ||| ?",
          fact.name,
          ^literal
        )
    )
  end

  defp maybe_where_package(queryable, nil), do: queryable

  defp maybe_where_package(queryable, package_id),
    do: where(queryable, [_fragment, fact], fact.package_id == ^package_id)

  defp maybe_where_package_version(queryable, nil), do: queryable

  defp maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [_fragment, fact], fact.package_version_id == ^package_version_id)

  defp contains?(value, literal), do: Text.literal_match?(to_string(value), literal)
end
