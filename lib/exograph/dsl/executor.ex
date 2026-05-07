defmodule Exograph.DSL.Executor do
  @moduledoc false

  import Ecto.Query

  alias Exograph.{CallEdgeHit, DefinitionHit, Hit, ReferenceHit}
  alias Exograph.DSL.{Plan, Planner, Query, Sources}
  alias Exograph.DSL.Plan.Join
  alias Exograph.Query, as: StructuralQuery

  alias Exograph.Postgres.{
    CallEdgeRecord,
    DefinitionRecord,
    FragmentRecord,
    Options,
    ReferenceRecord
  }

  def all(index, %Query{} = query, opts) do
    execute(index, Planner.plan(query), opts)
  end

  defp execute(index, %Plan{source: :fragment, joins: []} = plan, opts) do
    fragment_all(index, plan, opts)
  end

  defp execute(index, %Plan{source: :fragment, joins: [%Join{} | _joins]} = plan, opts) do
    fragment_join_all(index, plan, opts)
  end

  defp execute(
         index,
         %Plan{
           source: :definition,
           binding: binding,
           joins: [%Join{parent: binding, binding: join_binding, assoc: :calls}]
         } = plan,
         opts
       ) do
    definition_calls_join_all(index, plan, join_binding, opts)
  end

  defp execute(index, %Plan{source: :definition} = plan, opts) do
    symbol_fact_all(index, plan, opts, :definition)
  end

  defp execute(index, %Plan{source: :reference} = plan, opts) do
    symbol_fact_all(index, plan, opts, :reference)
  end

  defp execute(index, %Plan{source: :call_edge} = plan, opts) do
    call_edge_all(index, plan, opts)
  end

  defp fragment_all(index, plan, opts) do
    limit = Keyword.get(opts, :limit, 50)
    compiled_query = plan.query |> Exograph.DSL.Compiler.compile() |> StructuralQuery.selector()

    hits =
      index
      |> filtered_fragments(predicates(plan, plan.binding), plan.binding, opts)
      |> Enum.flat_map(&verify_fragment(&1, compiled_query))
      |> Enum.take(limit)

    {:ok, hits}
  end

  defp fragment_join_all(index, plan, opts) do
    limit = Keyword.get(query_opts = opts, :limit, 50)
    compiled_query = plan.query |> Exograph.DSL.Compiler.compile() |> StructuralQuery.selector()

    hits =
      index
      |> joined_fragments(plan, query_opts)
      |> Enum.flat_map(fn {fragment, joined_by_binding} ->
        fragment
        |> verify_fragment(compiled_query)
        |> Enum.map(&select_multi_fragment_join(plan, &1, joined_by_binding))
      end)
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

  defp joined_fragments(index, %Plan{joins: [join]} = plan, opts) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      join: joined in ^Sources.join_source(join.assoc, index.inverted.prefix),
      on: joined.file_id == fragment.file_id and fragment.line <= joined.line,
      where: fragment.kind in [:def, :defp, :defmacro, :defmacrop],
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, joined}
    )
    |> where_source_predicates(predicates(plan, plan.binding), nil, :fragment)
    |> where_second_binding_predicates(predicates(plan, join.binding), join.binding, join.assoc)
    |> where_fragment_scope(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path, joined} ->
      {
        Options.hydrate_fragment(fragment, source, path),
        %{join.binding => joined_value(join.assoc, joined)}
      }
    end)
  end

  defp joined_fragments(index, %Plan{joins: [first_join, second_join]} = plan, opts) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      join: first in ^Sources.join_source(first_join.assoc, index.inverted.prefix),
      on: first.file_id == fragment.file_id and fragment.line <= first.line,
      join: second in ^Sources.join_source(second_join.assoc, index.inverted.prefix),
      on: second.file_id == fragment.file_id and fragment.line <= second.line,
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.kind in [:def, :defp, :defmacro, :defmacrop],
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, first, second}
    )
    |> where_source_predicates(predicates(plan, plan.binding), nil, :fragment)
    |> where_second_binding_predicates(
      predicates(plan, first_join.binding),
      first_join.binding,
      first_join.assoc
    )
    |> where_third_binding_predicates(
      predicates(plan, second_join.binding),
      second_join.binding,
      second_join.assoc
    )
    |> where_fragment_scope(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path, first, second} ->
      {
        Options.hydrate_fragment(fragment, source, path),
        %{
          first_join.binding => joined_value(first_join.assoc, first),
          second_join.binding => joined_value(second_join.assoc, second)
        }
      }
    end)
  end

  defp joined_fragments(index, %Plan{joins: [first_join, second_join, third_join]} = plan, opts) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      join: first in ^Sources.join_source(first_join.assoc, index.inverted.prefix),
      on: first.file_id == fragment.file_id and fragment.line <= first.line,
      join: second in ^Sources.join_source(second_join.assoc, index.inverted.prefix),
      on: second.file_id == fragment.file_id and fragment.line <= second.line,
      join: third in ^Sources.join_source(third_join.assoc, index.inverted.prefix),
      on: third.file_id == fragment.file_id and fragment.line <= third.line,
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.kind in [:def, :defp, :defmacro, :defmacrop],
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, first, second, third}
    )
    |> where_source_predicates(predicates(plan, plan.binding), nil, :fragment)
    |> where_second_binding_predicates(
      predicates(plan, first_join.binding),
      first_join.binding,
      first_join.assoc
    )
    |> where_third_binding_predicates(
      predicates(plan, second_join.binding),
      second_join.binding,
      second_join.assoc
    )
    |> where_fourth_binding_predicates(
      predicates(plan, third_join.binding),
      third_join.binding,
      third_join.assoc
    )
    |> where_fragment_scope(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path, first, second, third} ->
      {
        Options.hydrate_fragment(fragment, source, path),
        %{
          first_join.binding => joined_value(first_join.assoc, first),
          second_join.binding => joined_value(second_join.assoc, second),
          third_join.binding => joined_value(third_join.assoc, third)
        }
      }
    end)
  end

  defp definition_calls_join_all(index, plan, call_edge_binding, opts) do
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
      |> where_source_predicates(predicates(plan, plan.binding), nil, :definition)
      |> where_second_binding_call_edge_predicates(
        predicates(plan, call_edge_binding),
        call_edge_binding
      )
      |> where_scope(opts)

    results =
      index.inverted.repo.all(queryable)
      |> Enum.map(&hit(&1, Options.definitions_source(index.inverted.prefix)))

    {:ok, results}
  end

  defp select_multi_fragment_join(%Plan{select: nil}, hit, _joined_by_binding), do: hit

  defp select_multi_fragment_join(
         %Plan{binding: binding, select: binding},
         hit,
         _joined_by_binding
       ),
       do: hit

  defp select_multi_fragment_join(
         %Plan{binding: binding, select: select},
         _hit,
         joined_by_binding
       )
       when is_atom(select) and select != binding do
    Map.fetch!(joined_by_binding, select)
  end

  defp select_multi_fragment_join(
         %Plan{binding: binding, select: {:tuple, bindings}},
         hit,
         joined_by_binding
       ) do
    bindings
    |> Enum.map(fn selected_binding ->
      if selected_binding == binding,
        do: hit,
        else: Map.fetch!(joined_by_binding, selected_binding)
    end)
    |> List.to_tuple()
  end

  defp joined_value(:definitions, joined), do: DefinitionRecord.to_definition(joined)
  defp joined_value(:references, joined), do: ReferenceRecord.to_reference(joined)
  defp joined_value(:calls, joined), do: CallEdgeRecord.to_call_edge(joined)

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

  defp symbol_fact_all(index, plan, opts, source_name) do
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
      |> where_source_predicates(predicates(plan, plan.binding), nil, source_name)
      |> where_scope(opts)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(&hit(&1, source))

    {:ok, results}
  end

  defp call_edge_all(index, plan, opts) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(edge in Options.call_edges_source(index.inverted.prefix),
        order_by: [asc: edge.caller_qualified_name, asc: edge.callee_qualified_name, asc: edge.id],
        limit: ^limit,
        select: edge
      )
      |> where_call_edge_predicates(predicates(plan, plan.binding))
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

  defp predicates(%Plan{predicates_by_binding: predicates_by_binding}, binding) do
    Map.get(predicates_by_binding, binding, [])
  end

  defp where_source_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_first_binding_predicate(query, predicate, source)
    end)
  end

  defp where_second_binding_call_edge_predicates(query, predicates, call_edge_binding) do
    where_second_binding_predicates(query, predicates, call_edge_binding, :calls)
  end

  defp where_second_binding_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_second_binding_predicate(query, predicate, source)
    end)
  end

  defp where_third_binding_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_third_binding_predicate(query, predicate, source)
    end)
  end

  defp where_fourth_binding_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_fourth_binding_predicate(query, predicate, source)
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

  defp where_first_binding_predicate(query, {:cmp, _binding, field, op, value}, source) do
    Sources.assert_field!(source, field)
    where_first_cmp(query, field, op, value)
  end

  defp where_first_binding_predicate(query, {:in, _binding, field, values}, source) do
    Sources.assert_field!(source, field)
    where(query, [row], field(row, ^field) in ^values)
  end

  defp where_second_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, row], ilike(field(row, ^field), ^"#{value}%"))
  end

  defp where_second_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, row], field(row, ^field) == ^value)
  end

  defp where_second_binding_predicate(query, {:cmp, _binding, field, op, value}, source) do
    Sources.assert_field!(source, field)
    where_second_cmp(query, field, op, value)
  end

  defp where_second_binding_predicate(query, {:in, _binding, field, values}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, row], field(row, ^field) in ^values)
  end

  defp where_third_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, row], ilike(field(row, ^field), ^"#{value}%"))
  end

  defp where_third_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, row], field(row, ^field) == ^value)
  end

  defp where_third_binding_predicate(query, {:cmp, _binding, field, op, value}, source) do
    Sources.assert_field!(source, field)
    where_third_cmp(query, field, op, value)
  end

  defp where_third_binding_predicate(query, {:in, _binding, field, values}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, row], field(row, ^field) in ^values)
  end

  defp where_fourth_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, _third, row], ilike(field(row, ^field), ^"#{value}%"))
  end

  defp where_fourth_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, _third, row], field(row, ^field) == ^value)
  end

  defp where_fourth_binding_predicate(query, {:cmp, _binding, field, op, value}, source) do
    Sources.assert_field!(source, field)
    where_fourth_cmp(query, field, op, value)
  end

  defp where_fourth_binding_predicate(query, {:in, _binding, field, values}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, _third, row], field(row, ^field) in ^values)
  end

  defp where_first_cmp(query, field, :>, value),
    do: where(query, [row], field(row, ^field) > ^value)

  defp where_first_cmp(query, field, :<, value),
    do: where(query, [row], field(row, ^field) < ^value)

  defp where_first_cmp(query, field, :>=, value),
    do: where(query, [row], field(row, ^field) >= ^value)

  defp where_first_cmp(query, field, :<=, value),
    do: where(query, [row], field(row, ^field) <= ^value)

  defp where_second_cmp(query, field, :>, value),
    do: where(query, [_first, row], field(row, ^field) > ^value)

  defp where_second_cmp(query, field, :<, value),
    do: where(query, [_first, row], field(row, ^field) < ^value)

  defp where_second_cmp(query, field, :>=, value),
    do: where(query, [_first, row], field(row, ^field) >= ^value)

  defp where_second_cmp(query, field, :<=, value),
    do: where(query, [_first, row], field(row, ^field) <= ^value)

  defp where_third_cmp(query, field, :>, value),
    do: where(query, [_first, _second, row], field(row, ^field) > ^value)

  defp where_third_cmp(query, field, :<, value),
    do: where(query, [_first, _second, row], field(row, ^field) < ^value)

  defp where_third_cmp(query, field, :>=, value),
    do: where(query, [_first, _second, row], field(row, ^field) >= ^value)

  defp where_third_cmp(query, field, :<=, value),
    do: where(query, [_first, _second, row], field(row, ^field) <= ^value)

  defp where_fourth_cmp(query, field, :>, value),
    do: where(query, [_first, _second, _third, row], field(row, ^field) > ^value)

  defp where_fourth_cmp(query, field, :<, value),
    do: where(query, [_first, _second, _third, row], field(row, ^field) < ^value)

  defp where_fourth_cmp(query, field, :>=, value),
    do: where(query, [_first, _second, _third, row], field(row, ^field) >= ^value)

  defp where_fourth_cmp(query, field, :<=, value),
    do: where(query, [_first, _second, _third, row], field(row, ^field) <= ^value)

  defp predicates_for(predicates, nil), do: Enum.filter(predicates, &field_predicate?/1)

  defp predicates_for(predicates, binding) do
    Enum.filter(predicates, fn
      {_kind, ^binding, _field, _value} -> true
      {:cmp, ^binding, _field, _op, _value} -> true
      _predicate -> false
    end)
  end

  defp field_predicate?({_kind, _binding, _field, _value}), do: true
  defp field_predicate?({:cmp, _binding, _field, _op, _value}), do: true
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
