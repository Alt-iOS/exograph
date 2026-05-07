defmodule Exograph.DSL.Executor do
  @moduledoc false

  import Ecto.Query

  alias Exograph.{CallEdgeHit, DefinitionHit, ReferenceHit}
  alias Exograph.DSL.Query

  alias Exograph.Postgres.{
    CallEdgeRecord,
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

  @call_edge_fields MapSet.new([
                      :id,
                      :package_id,
                      :package_version_id,
                      :file_id,
                      :caller_node_id,
                      :callee_node_id,
                      :call_site_fragment_id,
                      :caller_qualified_name,
                      :callee_qualified_name,
                      :line,
                      :column
                    ])

  def all(index, %Query{source: :definition, predicates: predicates}, opts) do
    symbol_fact_all(index, predicates, opts, Options.definitions_source(index.inverted.prefix))
  end

  def all(index, %Query{source: :reference, predicates: predicates}, opts) do
    symbol_fact_all(index, predicates, opts, Options.references_source(index.inverted.prefix))
  end

  def all(index, %Query{source: :call_edge, predicates: predicates}, opts) do
    call_edge_all(index, predicates, opts)
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
      |> where_symbol_fact_predicates(predicates)
      |> where_scope(opts)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(&hit(&1, source))

    {:ok, results}
  end

  defp call_edge_all(index, predicates, opts) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(edge in Options.call_edges_source(index.inverted.prefix),
        order_by: [asc: edge.caller_qualified_name, asc: edge.callee_qualified_name, asc: edge.id],
        limit: ^limit,
        select: edge
      )
      |> where_call_edge_predicates(predicates)
      |> where_scope(opts)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(fn edge ->
        CallEdgeHit.new(call_edge: CallEdgeRecord.to_call_edge(edge), score: 1.0)
      end)

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

  defp where_symbol_fact_predicates(query, predicates) do
    Enum.reduce(predicates, query, fn
      {:prefix_search, _binding, field, value}, query ->
        assert_symbol_fact_field!(field)
        where(query, [fact], ilike(field(fact, ^field), ^"#{value}%"))

      {:eq, _binding, field, value}, query ->
        assert_symbol_fact_field!(field)
        where(query, [fact], field(fact, ^field) == ^value)
    end)
  end

  defp where_call_edge_predicates(query, predicates) do
    Enum.reduce(predicates, query, fn
      {:prefix_search, _binding, field, value}, query ->
        assert_call_edge_field!(field)
        where(query, [edge], ilike(field(edge, ^field), ^"#{value}%"))

      {:eq, _binding, field, value}, query ->
        assert_call_edge_field!(field)
        where(query, [edge], field(edge, ^field) == ^value)
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
    do: where(queryable, [row], row.package_id == ^package_id)

  defp maybe_where_package_version(queryable, nil), do: queryable

  defp maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [row], row.package_version_id == ^package_version_id)

  defp assert_symbol_fact_field!(field) do
    unless MapSet.member?(@symbol_fact_fields, field) do
      raise ArgumentError, "unsupported symbol fact field in Exograph DSL: #{field}"
    end
  end

  defp assert_call_edge_field!(field) do
    unless MapSet.member?(@call_edge_fields, field) do
      raise ArgumentError, "unsupported CallEdge field in Exograph DSL: #{field}"
    end
  end

  defp hydrate_fragment(nil, _source, _path), do: nil

  defp hydrate_fragment(fragment, source, path),
    do: Options.hydrate_fragment(fragment, source, path)
end
