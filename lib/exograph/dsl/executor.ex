defmodule Exograph.DSL.Executor do
  @moduledoc false

  import Ecto.Query

  alias Exograph.{CallEdgeHit, DefinitionHit, Hit, ReferenceHit}
  alias Exograph.DSL.{Query, Sources}
  alias Exograph.Query, as: StructuralQuery

  alias Exograph.Postgres.{
    CallEdgeRecord,
    DefinitionRecord,
    FragmentRecord,
    Options,
    ReferenceRecord
  }

  def all(index, %Query{source: :fragment, joins: []} = query, opts) do
    fragment_all(index, query, opts)
  end

  def all(
        index,
        %Query{
          source: :fragment,
          binding: binding,
          joins: [{:assoc, binding, join_binding, assoc}]
        } = query,
        opts
      )
      when assoc in [:definitions, :references, :calls] do
    fragment_join_all(index, query, join_binding, assoc, opts)
  end

  def all(
        index,
        %Query{
          source: :definition,
          binding: binding,
          joins: [{:assoc, binding, join_binding, :calls}]
        } = query,
        opts
      ) do
    definition_calls_join_all(index, query, join_binding, opts)
  end

  def all(index, %Query{source: :definition, predicates: predicates}, opts) do
    symbol_fact_all(index, predicates, opts, :definition)
  end

  def all(index, %Query{source: :reference, predicates: predicates}, opts) do
    symbol_fact_all(index, predicates, opts, :reference)
  end

  def all(index, %Query{source: :call_edge, predicates: predicates}, opts) do
    call_edge_all(index, predicates, opts)
  end

  defp fragment_all(index, query, opts) do
    limit = Keyword.get(opts, :limit, 50)
    compiled_query = query |> Exograph.DSL.Compiler.compile() |> StructuralQuery.selector()

    hits =
      index
      |> filtered_fragments(query.predicates, query.binding, opts)
      |> Enum.flat_map(&verify_fragment(&1, compiled_query))
      |> Enum.take(limit)

    {:ok, hits}
  end

  defp fragment_join_all(index, query, join_binding, assoc, opts) do
    limit = Keyword.get(query_opts = opts, :limit, 50)
    compiled_query = query |> Exograph.DSL.Compiler.compile() |> StructuralQuery.selector()

    hits =
      index
      |> joined_fragments(query.predicates, join_binding, assoc, query_opts)
      |> Enum.flat_map(&verify_fragment(&1, compiled_query))
      |> Enum.take(limit)

    {:ok, hits}
  end

  defp filtered_fragments(index, predicates, binding, opts) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path}
    )
    |> where_source_predicates(predicates, binding, :fragment)
    |> where_fragment_scope(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path} ->
      Options.hydrate_fragment(fragment, source, path)
    end)
  end

  defp joined_fragments(index, predicates, join_binding, assoc, opts) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      join: joined in ^Sources.join_source(assoc, index.inverted.prefix),
      on: joined.file_id == fragment.file_id and fragment.line <= joined.line,
      where: fragment.kind in [:def, :defp, :defmacro, :defmacrop],
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path}
    )
    |> where_join_predicates(predicates, join_binding, assoc)
    |> where_fragment_scope(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path} ->
      Options.hydrate_fragment(fragment, source, path)
    end)
  end

  defp definition_calls_join_all(index, query, call_edge_binding, opts) do
    limit = Keyword.get(opts, :limit, 50)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    queryable =
      from(definition in Options.definitions_source(index.inverted.prefix),
        join: edge in ^Options.call_edges_source(index.inverted.prefix),
        on: edge.caller_qualified_name == definition.qualified_name,
        left_join: fragment in ^{fragments_source, FragmentRecord},
        on: fragment.id == definition.fragment_id,
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: definition.qualified_name, asc: edge.callee_qualified_name, asc: edge.id],
        limit: ^limit,
        select: {definition, fragment, nil, file.path}
      )
      |> where_source_predicates(query.predicates, query.binding, :definition)
      |> where_second_binding_call_edge_predicates(query.predicates, call_edge_binding)
      |> where_scope(opts)

    results =
      index.inverted.repo.all(queryable)
      |> Enum.map(&hit(&1, Options.definitions_source(index.inverted.prefix)))

    {:ok, results}
  end

  defp verify_fragment(fragment, compiled_query) do
    case StructuralQuery.verify(compiled_query, fragment) do
      {:ok, matches} ->
        Enum.map(matches, &Hit.with_match(Hit.new(fragment: fragment, score: 1.0), &1))

      :error ->
        []
    end
  end

  defp candidate_limit(index, opts) do
    Keyword.get_lazy(opts, :candidate_limit, fn ->
      index.fragment_store_backend.count(index.fragment_store)
    end)
  end

  defp symbol_fact_all(index, predicates, opts, source_name) do
    source = Sources.source(source_name, index.inverted.prefix)
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
      |> where_source_predicates(predicates, nil, source_name)
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

  defp where_join_predicates(query, predicates, join_binding, assoc) do
    predicates
    |> predicates_for(join_binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_second_binding_predicate(query, predicate, assoc)
    end)
  end

  defp where_source_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_first_binding_predicate(query, predicate, source)
    end)
  end

  defp where_second_binding_call_edge_predicates(query, predicates, call_edge_binding) do
    predicates
    |> predicates_for(call_edge_binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_second_binding_predicate(query, predicate, :calls)
    end)
  end

  defp where_call_edge_predicates(query, predicates) do
    Enum.reduce(predicates, query, fn predicate, query ->
      where_first_binding_predicate(query, predicate, :call_edge)
    end)
  end

  defp where_first_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [row], ilike(field(row, ^field), ^"#{value}%"))
  end

  defp where_first_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [row], field(row, ^field) == ^value)
  end

  defp where_second_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, row], ilike(field(row, ^field), ^"#{value}%"))
  end

  defp where_second_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, row], field(row, ^field) == ^value)
  end

  defp predicates_for(predicates, nil), do: Enum.filter(predicates, &field_predicate?/1)

  defp predicates_for(predicates, binding) do
    Enum.filter(predicates, fn
      {_kind, ^binding, _field, _value} -> true
      _predicate -> false
    end)
  end

  defp field_predicate?({_kind, _binding, _field, _value}), do: true
  defp field_predicate?(_predicate), do: false

  defp where_fragment_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_fragment_package(package_id)
    |> maybe_where_fragment_package_version(package_version_id)
  end

  defp maybe_where_fragment_package(queryable, nil), do: queryable

  defp maybe_where_fragment_package(queryable, package_id),
    do: where(queryable, [fragment], fragment.package_id == ^package_id)

  defp maybe_where_fragment_package_version(queryable, nil), do: queryable

  defp maybe_where_fragment_package_version(queryable, package_version_id),
    do: where(queryable, [fragment], fragment.package_version_id == ^package_version_id)

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

  defp hydrate_fragment(nil, _source, _path), do: nil

  defp hydrate_fragment(fragment, source, path),
    do: Options.hydrate_fragment(fragment, source, path)
end
