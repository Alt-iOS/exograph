defmodule Exograph.DSL.Executor do
  @moduledoc false

  import Ecto.Query

  alias Exograph.DefinitionHit
  alias Exograph.DSL.Query
  alias Exograph.Postgres.{DefinitionRecord, FragmentRecord, Options}

  @definition_fields MapSet.new([
                       :id,
                       :package_id,
                       :package_version_id,
                       :file_id,
                       :fragment_id,
                       :kind,
                       :module,
                       :name,
                       :arity,
                       :qualified_name,
                       :mfa_module,
                       :mfa_name,
                       :mfa_arity,
                       :line,
                       :column
                     ])

  def all(index, %Query{source: :definition, predicates: predicates}, opts) do
    limit = Keyword.get(opts, :limit, 50)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    query =
      from(definition in Options.definitions_source(index.inverted.prefix),
        left_join: fragment in ^{fragments_source, FragmentRecord},
        on: fragment.id == definition.fragment_id,
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: definition.qualified_name, asc: definition.line, asc: definition.id],
        limit: ^limit,
        select: {definition, fragment, nil, file.path}
      )
      |> where_predicates(predicates)
      |> where_scope(opts)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(fn {definition, fragment, source, path} ->
        DefinitionHit.new(
          definition: DefinitionRecord.to_definition(definition),
          fragment: hydrate_fragment(fragment, source, path),
          score: 1.0
        )
      end)

    {:ok, results}
  end

  defp where_predicates(query, predicates) do
    Enum.reduce(predicates, query, fn
      {:prefix_search, _binding, field, value}, query ->
        assert_definition_field!(field)
        where(query, [definition], ilike(field(definition, ^field), ^"#{value}%"))

      {:eq, _binding, field, value}, query ->
        assert_definition_field!(field)
        where(query, [definition], field(definition, ^field) == ^value)
    end)
  end

  defp where_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_package(package_id)
    |> maybe_where_package_version(package_version_id)
  end

  defp maybe_where_package(queryable, nil), do: queryable

  defp maybe_where_package(queryable, package_id),
    do: where(queryable, [definition], definition.package_id == ^package_id)

  defp maybe_where_package_version(queryable, nil), do: queryable

  defp maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [definition], definition.package_version_id == ^package_version_id)

  defp assert_definition_field!(field) do
    unless MapSet.member?(@definition_fields, field) do
      raise ArgumentError, "unsupported Definition field in Exograph DSL: #{field}"
    end
  end

  defp hydrate_fragment(nil, _source, _path), do: nil

  defp hydrate_fragment(fragment, source, path),
    do: Options.hydrate_fragment(fragment, source, path)
end
