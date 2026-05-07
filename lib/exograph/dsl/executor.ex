defmodule Exograph.DSL.Executor do
  @moduledoc false

  import Ecto.Query

  alias Exograph.{DefinitionHit, ReferenceHit}
  alias Exograph.DSL.Query

  alias Exograph.Postgres.{
    DefinitionRecord,
    FragmentRecord,
    Options,
    ReferenceRecord
  }

  @symbol_fact_fields MapSet.new([
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
    symbol_fact_all(index, predicates, opts, Options.definitions_source(index.inverted.prefix))
  end

  def all(index, %Query{source: :reference, predicates: predicates}, opts) do
    symbol_fact_all(index, predicates, opts, Options.references_source(index.inverted.prefix))
  end

  defp symbol_fact_all(index, predicates, opts, source) do
    limit = Keyword.get(opts, :limit, 50)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    query =
      from(fact in source,
        left_join: fragment in ^{fragments_source, FragmentRecord},
        on: fragment.id == fact.fragment_id,
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: fact.qualified_name, asc: fact.line, asc: fact.id],
        limit: ^limit,
        select: {fact, fragment, nil, file.path}
      )
      |> where_predicates(predicates)
      |> where_scope(opts)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(&hit(&1, source))

    {:ok, results}
  end

  defp hit({fact, fragment, source, path}, {_table, DefinitionRecord}) do
    DefinitionHit.new(
      definition: DefinitionRecord.to_definition(fact),
      fragment: hydrate_fragment(fragment, source, path),
      score: 1.0
    )
  end

  defp hit({fact, fragment, source, path}, {_table, ReferenceRecord}) do
    ReferenceHit.new(
      reference: ReferenceRecord.to_reference(fact),
      fragment: hydrate_fragment(fragment, source, path),
      score: 1.0
    )
  end

  defp where_predicates(query, predicates) do
    Enum.reduce(predicates, query, fn
      {:prefix_search, _binding, field, value}, query ->
        assert_symbol_fact_field!(field)
        where(query, [fact], ilike(field(fact, ^field), ^"#{value}%"))

      {:eq, _binding, field, value}, query ->
        assert_symbol_fact_field!(field)
        where(query, [fact], field(fact, ^field) == ^value)
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
    do: where(queryable, [fact], fact.package_id == ^package_id)

  defp maybe_where_package_version(queryable, nil), do: queryable

  defp maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [fact], fact.package_version_id == ^package_version_id)

  defp assert_symbol_fact_field!(field) do
    unless MapSet.member?(@symbol_fact_fields, field) do
      raise ArgumentError, "unsupported symbol fact field in Exograph DSL: #{field}"
    end
  end

  defp hydrate_fragment(nil, _source, _path), do: nil

  defp hydrate_fragment(fragment, source, path),
    do: Options.hydrate_fragment(fragment, source, path)
end
