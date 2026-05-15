defmodule Exograph.DSL.Executor do
  @moduledoc false

  import Ecto.Query
  import Exograph.DSL.Executor.Predicates
  import Exograph.DSL.Executor.Scope

  alias Exograph.{CallEdgeHit, DefinitionHit, Hit, ReferenceHit}
  alias Exograph.DSL.{Compiler, JoinSemantics, Plan, Planner, Query, Sources}
  alias Exograph.DSL.Plan.Join
  alias Exograph.Postgres.FragmentStore, as: PostgresFragmentStore
  alias Exograph.Postgres.InvertedIndex, as: PostgresInvertedIndex
  alias Exograph.StructuralQuery

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
    compiled_query = plan.query |> Compiler.compile() |> StructuralQuery.selector()

    hits =
      index
      |> stream_filtered_fragments(plan, opts)
      |> Stream.flat_map(&verify_fragment(&1, compiled_query))
      |> Enum.take(limit)

    {:ok, hits}
  end

  defp fragment_join_all(index, plan, opts) do
    limit = Keyword.get(query_opts = opts, :limit, 50)
    compiled_query = plan.query |> Compiler.compile() |> StructuralQuery.selector()

    hits =
      index
      |> stream_joined_fragments(plan, query_opts)
      |> Stream.flat_map(fn {fragment, joined_by_binding} ->
        fragment
        |> verify_fragment(compiled_query)
        |> Enum.map(&select_multi_fragment_join(plan, &1, joined_by_binding))
      end)
      |> Enum.take(limit)

    {:ok, hits}
  end

  @stream_batch_size 500

  defp stream_filtered_fragments(index, plan, opts) do
    Stream.resource(
      fn -> {0, false} end,
      fn
        {_offset, true} ->
          {:halt, :done}

        {offset, false} ->
          batch = filtered_fragment_batch(index, plan, opts, offset)
          done = length(batch) < @stream_batch_size
          {batch, {offset + length(batch), done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp filtered_fragment_batch(index, plan, opts, offset) do
    base_fragment_query(index, offset)
    |> where_structural_terms(index, plan)
    |> where_source_predicates(predicates(plan, plan.binding), plan.binding, :fragment)
    |> where_fragment_scope(opts)
    |> hydrate_fragment_batch(index)
  end

  def stream_structural(index, %Exograph.StructuralQuery{} = compiled_query, opts) do
    term_strings = MapSet.to_list(compiled_query.required_terms)
    term_ids = PostgresInvertedIndex.resolve_term_ids(index.inverted, term_strings)

    Stream.resource(
      fn -> {0, false} end,
      fn
        {_offset, true} ->
          {:halt, :done}

        {offset, false} ->
          batch = structural_fragment_batch(index, term_ids, opts, offset)
          done = length(batch) < @stream_batch_size
          {batch, {offset + length(batch), done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp structural_fragment_batch(index, term_ids, opts, offset) do
    query = base_fragment_query(index, offset)

    query =
      if term_ids != [],
        do: where(query, [fragment], fragment("? @> ?", fragment.terms, ^term_ids)),
        else: query

    query
    |> where_fragment_scope(opts)
    |> hydrate_fragment_batch(index)
  end

  defp base_fragment_query(index, offset) do
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      offset: ^offset,
      limit: ^@stream_batch_size,
      select: {fragment, file.source, file.path}
    )
  end

  defp hydrate_fragment_batch(query, index) do
    index.inverted.repo.all(query)
    |> Enum.map(fn {fragment, source, path} ->
      Options.hydrate_fragment(fragment, source, path)
    end)
  end

  defp stream_joined_fragments(index, %Plan{joins: [_]} = plan, opts) do
    Stream.resource(
      fn -> {0, false} end,
      fn
        {_offset, true} ->
          {:halt, :done}

        {offset, false} ->
          batch_opts = Keyword.put(opts, :candidate_limit, @stream_batch_size)
          batch = joined_fragments(index, plan, batch_opts, offset)
          done = length(batch) < @stream_batch_size
          {batch, {offset + length(batch), done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp stream_joined_fragments(index, plan, opts) do
    joined_fragments(
      index,
      plan,
      Keyword.put_new_lazy(opts, :candidate_limit, fn ->
        PostgresFragmentStore.count(index.fragment_store)
      end),
      0
    )
  end

  defp joined_fragments(index, %Plan{joins: [join]} = plan, opts, offset) do
    join_predicates = predicates(plan, join.binding)

    if join_predicates != [] do
      joined_fragments_fact_first(index, plan, join, opts, offset)
    else
      joined_fragments_fragment_first(index, plan, join, opts, offset)
    end
  end

  defp joined_fragments(index, %Plan{joins: [_first, _second]} = plan, opts, _offset),
    do: joined_fragments_two(index, plan, opts)

  defp joined_fragments(index, %Plan{joins: [_first, _second, _third]} = plan, opts, _offset),
    do: joined_fragments_three(index, plan, opts)

  defp joined_fragments_fact_first(index, plan, join, opts, offset) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)
    function_fragment_kinds = JoinSemantics.function_fragment_kinds()

    {join_table, join_record} = Sources.primary_source(join.assoc, index.inverted.prefix)

    from(joined in {join_table, join_record},
      join: fragment in ^{fragments_source, FragmentRecord},
      as: :fragment,
      on: fragment.file_id == joined.file_id and fragment.kind in ^function_fragment_kinds,
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      where:
        joined.line >= fragment.line and
          (is_nil(fragment.end_line) or joined.line <= fragment.end_line),
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      offset: ^offset,
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, joined}
    )
    |> where_first_binding_join_predicates(predicates(plan, join.binding), join.assoc)
    |> where_structural_terms_second(index, plan)
    |> where_second_binding_predicates(predicates(plan, plan.binding), plan.binding, :fragment)
    |> where_fragment_scope_second(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path, joined} ->
      {
        Options.hydrate_fragment(fragment, source, path),
        %{join.binding => joined_value(join.assoc, joined)}
      }
    end)
  end

  defp joined_fragments_fragment_first(index, plan, join, opts, offset) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)
    function_fragment_kinds = JoinSemantics.function_fragment_kinds()

    from(fragment in {fragments_source, FragmentRecord},
      as: :fragment,
      join: joined in ^Sources.join_source(join.assoc, index.inverted.prefix),
      on: joined.file_id == fragment.file_id,
      where:
        fragment.kind in ^function_fragment_kinds and joined.line >= fragment.line and
          (is_nil(fragment.end_line) or joined.line <= fragment.end_line),
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      offset: ^offset,
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, joined}
    )
    |> where_structural_terms(index, plan)
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

  defp joined_fragments_two(index, %Plan{joins: [first_join, second_join]} = plan, opts) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)
    function_fragment_kinds = JoinSemantics.function_fragment_kinds()

    from(fragment in {fragments_source, FragmentRecord},
      as: :fragment,
      join: first in ^Sources.join_source(first_join.assoc, index.inverted.prefix),
      on:
        first.file_id == fragment.file_id and first.line >= fragment.line and
          (is_nil(fragment.end_line) or first.line <= fragment.end_line),
      join: second in ^Sources.join_source(second_join.assoc, index.inverted.prefix),
      on:
        second.file_id == fragment.file_id and second.line >= fragment.line and
          (is_nil(fragment.end_line) or second.line <= fragment.end_line),
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.kind in ^function_fragment_kinds,
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, first, second}
    )
    |> JoinSemantics.where_call_definition_pairs(plan)
    |> where_structural_terms(index, plan)
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

  defp joined_fragments_three(
         index,
         %Plan{joins: [first_join, second_join, third_join]} = plan,
         opts
       ) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)
    function_fragment_kinds = JoinSemantics.function_fragment_kinds()

    from(fragment in {fragments_source, FragmentRecord},
      as: :fragment,
      join: first in ^Sources.join_source(first_join.assoc, index.inverted.prefix),
      on:
        first.file_id == fragment.file_id and first.line >= fragment.line and
          (is_nil(fragment.end_line) or first.line <= fragment.end_line),
      join: second in ^Sources.join_source(second_join.assoc, index.inverted.prefix),
      on:
        second.file_id == fragment.file_id and second.line >= fragment.line and
          (is_nil(fragment.end_line) or second.line <= fragment.end_line),
      join: third in ^Sources.join_source(third_join.assoc, index.inverted.prefix),
      on: third.file_id == fragment.file_id,
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.kind in ^function_fragment_kinds,
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, first, second, third}
    )
    |> JoinSemantics.where_call_definition_pairs(plan)
    |> where_structural_terms(index, plan)
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
      PostgresFragmentStore.count(index.fragment_store)
    end)
  end

  defp predicates(%Plan{predicates_by_binding: predicates_by_binding}, binding) do
    Map.get(predicates_by_binding, binding, [])
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

  defp hydrate_fragment(nil, _source, _path), do: nil

  defp hydrate_fragment(fragment, source, path),
    do: Options.hydrate_fragment(fragment, source, path)
end
