defmodule Exograph.Planner do
  @moduledoc false

  alias Exograph.Planner.{LogicalPlan, PhysicalPlan, Plan, Stats}
  alias Exograph.{Hit, Index, Query}

  @spec plan(Index.t(), Query.t(), keyword()) :: Plan.t()
  def plan(%Index{} = index, %Query{} = query, opts \\ []) do
    stats = Keyword.get_lazy(opts, :stats, fn -> Stats.collect(index, query) end)
    logical = LogicalPlan.from_query(query)
    limit = Keyword.get(opts, :limit, 50)
    verify? = Keyword.get(opts, :verify, true)
    required = MapSet.to_list(query.required_terms)
    candidate_groups = Enum.map(query.candidate_groups, &MapSet.to_list/1)

    {scan, fallback?, warnings} = scan_choice(required, candidate_groups, stats)

    physical = %PhysicalPlan{
      scan: scan,
      filters: filters(verify?),
      limit: limit,
      verify?: verify?,
      fallback?: fallback?
    }

    %Plan{
      query: query,
      logical: logical,
      physical: physical,
      estimated_candidates: estimate(scan, stats),
      warnings: warnings
    }
  end

  @spec execute(Index.t(), Plan.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def execute(%Index{} = index, %Plan{} = plan, opts \\ []) do
    with {:ok, hits} <- scan(index, plan, opts),
         {:ok, hits} <- hydrate_hits(index, hits) do
      results =
        if plan.physical.verify? do
          verify_hits(hits, plan.query, plan.physical.limit)
        else
          hits
        end

      {:ok, results |> filter_scope(opts) |> Enum.take(plan.physical.limit)}
    end
  end

  @spec explain(Plan.t()) :: map()
  def explain(%Plan{} = plan) do
    %{
      logical: %{
        required_terms: plan.logical.required_terms |> MapSet.to_list() |> Enum.sort(),
        optional_terms: plan.logical.optional_terms |> MapSet.to_list() |> Enum.sort(),
        verifier_only_negative_terms:
          plan.logical.verifier_only_negative_terms |> MapSet.to_list() |> Enum.sort(),
        candidate_groups:
          Enum.map(plan.logical.candidate_groups, fn group ->
            group |> MapSet.to_list() |> Enum.sort()
          end),
        verifier: verifier_name(plan.logical.verifier)
      },
      physical: %{
        scan: plan.physical.scan,
        filters: plan.physical.filters,
        fallback?: plan.physical.fallback?,
        verify?: plan.physical.verify?,
        limit: plan.physical.limit
      },
      estimated_candidates: plan.estimated_candidates,
      warnings: plan.warnings
    }
  end

  defp scan_choice([], [], stats) do
    warnings = if stats.fragment_count > 1_000, do: [:broad_query], else: []
    {:fragment_seq_scan, true, warnings}
  end

  defp scan_choice(required, [], _stats), do: {{:term_index_scan, required}, false, []}

  defp scan_choice(required, candidate_groups, _stats) do
    groups = Enum.map(candidate_groups, &Enum.uniq(required ++ &1))
    {{:union_term_index_scan, groups}, false, []}
  end

  defp estimate(:fragment_seq_scan, stats), do: stats.fragment_count
  defp estimate({:term_index_scan, terms}, stats), do: Stats.estimate_terms(stats, terms)

  defp estimate({:union_term_index_scan, groups}, stats) do
    Enum.reduce_while(groups, 0, fn group, acc ->
      case Stats.estimate_terms(stats, group) do
        :unknown -> {:halt, :unknown}
        estimate -> {:cont, acc + estimate}
      end
    end)
  end

  defp filters(false), do: [:hydrate_fragments]
  defp filters(true), do: [:hydrate_fragments, :ex_ast_verify]

  defp scan(index, %Plan{physical: %PhysicalPlan{scan: :fragment_seq_scan} = physical}, opts) do
    hits =
      index
      |> stream_all_fragments(opts)
      |> Stream.map(&Hit.new(fragment: &1, score: 1.0))
      |> maybe_take_candidates(physical)

    {:ok, Enum.to_list(hits)}
  end

  defp scan(index, %Plan{physical: %PhysicalPlan{scan: {:term_index_scan, _terms}}} = plan, opts) do
    opts = candidate_opts(index, plan, opts)

    case index.inverted_backend.search(index.inverted, plan.query, opts) do
      {:ok, hits} ->
        {:ok, hits}

      {:error, _reason} ->
        scan(
          index,
          %{plan | physical: %{plan.physical | scan: :fragment_seq_scan, fallback?: true}},
          opts
        )
    end
  end

  defp scan(
         index,
         %Plan{physical: %PhysicalPlan{scan: {:union_term_index_scan, groups}}} = plan,
         opts
       ) do
    opts = candidate_opts(index, plan, opts)

    groups
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, acc} ->
      query = %{plan.query | required_terms: MapSet.new(group)}

      case index.inverted_backend.search(index.inverted, query, opts) do
        {:ok, hits} -> {:cont, {:ok, [hits | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hit_groups} ->
        {:ok, hit_groups |> List.flatten() |> Enum.uniq_by(&hit_key/1)}

      {:error, _reason} ->
        scan(
          index,
          %{plan | physical: %{plan.physical | scan: :fragment_seq_scan, fallback?: true}},
          opts
        )
    end
  end

  defp candidate_opts(_index, %Plan{physical: %PhysicalPlan{verify?: false, limit: limit}}, opts) do
    Keyword.put(opts, :limit, limit)
  end

  defp candidate_opts(index, %Plan{physical: %PhysicalPlan{verify?: true}}, opts) do
    candidate_limit = Keyword.get_lazy(opts, :candidate_limit, fn -> candidate_count(index) end)
    Keyword.put(opts, :limit, candidate_limit)
  end

  defp maybe_take_candidates(hits, %PhysicalPlan{verify?: true}), do: hits

  defp maybe_take_candidates(hits, %PhysicalPlan{verify?: false, limit: limit}),
    do: Stream.take(hits, limit)

  defp candidate_count(index) do
    index.fragment_store_backend.count(index.fragment_store)
  end

  @stream_batch_size 500

  defp stream_all_fragments(index, opts) do
    Stream.resource(
      fn -> {0, false} end,
      fn
        {_offset, true} ->
          {:halt, :done}

        {offset, false} ->
          batch =
            index.fragment_store_backend.page(
              index.fragment_store,
              offset,
              @stream_batch_size,
              opts
            )

          done = length(batch) < @stream_batch_size
          {batch, {offset + length(batch), done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp hit_key(%{fragment_id: fragment_id}) when not is_nil(fragment_id), do: fragment_id
  defp hit_key(%{fragment: fragment}) when not is_nil(fragment), do: fragment.id

  defp hydrate_hits(%Index{} = index, hits) do
    hits
    |> Enum.reduce_while({:ok, []}, fn hit, {:ok, acc} ->
      case hydrate_hit(index, hit) do
        {:ok, hit} -> {:cont, {:ok, [hit | acc]}}
        :error -> {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, hits} -> {:ok, Enum.reverse(hits)}
      error -> error
    end
  end

  defp hydrate_hit(_index, %{fragment: fragment} = hit) when not is_nil(fragment), do: {:ok, hit}

  defp hydrate_hit(index, %{fragment_id: fragment_id} = hit) do
    case index.fragment_store_backend.get(index.fragment_store, fragment_id) do
      {:ok, fragment} -> {:ok, %{hit | fragment: fragment}}
      :error -> :error
    end
  end

  defp filter_scope(results, opts) do
    package_id = Keyword.get(opts, :package_id)
    package_version_id = Keyword.get(opts, :package_version_id)
    package_version = Keyword.get(opts, :package_version)

    Enum.filter(results, fn %{fragment: fragment} ->
      (is_nil(package_id) or fragment.package_id == package_id) and
        (is_nil(package_version_id) or fragment.package_version_id == package_version_id) and
        (is_nil(package_version) or fragment.package_version_id == package_version)
    end)
  end

  defp verify_hits(hits, query, limit) do
    {results, _keys} =
      Enum.reduce_while(hits, {[], MapSet.new()}, fn hit, {acc, keys} ->
        {acc, keys} =
          hit
          |> verified_matches(query)
          |> Enum.reduce({acc, keys}, fn result, {acc, keys} ->
            key = result_key(result)

            if MapSet.member?(keys, key) do
              {acc, keys}
            else
              {[result | acc], MapSet.put(keys, key)}
            end
          end)

        if length(acc) >= limit do
          {:halt, {acc, keys}}
        else
          {:cont, {acc, keys}}
        end
      end)

    results |> Enum.reverse() |> Enum.take(limit)
  end

  defp verified_matches(hit, query) do
    if comment_prefilter?(query, hit.fragment) do
      case Query.verify(query, hit.fragment) do
        {:ok, matches} ->
          matches
          |> Enum.filter(&compatible_match?(&1, hit.fragment))
          |> Enum.map(&Hit.with_match(hit, &1))

        :error ->
          []
      end
    else
      []
    end
  end

  defp comment_prefilter?(query, fragment) do
    case Query.comment_texts(query) do
      [] -> true
      texts -> Enum.any?(texts, &String.contains?(source_window(fragment), &1))
    end
  end

  defp source_window(%{source: source, ast: ast, line: line}) when is_binary(source) do
    lines = String.split(source, "\n")
    last_line = max_ast_line(ast, line) + 20

    lines
    |> Enum.slice(max(line - 21, 0)..last_line)
    |> Enum.join("\n")
  end

  defp source_window(_fragment), do: ""

  defp max_ast_line(ast, default) do
    {_ast, max_line} =
      Macro.prewalk(ast, default, fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          {node, max(acc, Keyword.get(meta, :line, acc))}

        node, acc ->
          {node, acc}
      end)

    max_line
  end

  defp compatible_match?(%{node: {:defmodule, _meta, _args}}, %{kind: kind}), do: kind == :module

  defp compatible_match?(%{node: {form, _meta, _args}}, %{kind: kind})
       when form in [:def, :defp, :defmacro, :defmacrop],
       do: kind == form

  defp compatible_match?(_match, _fragment), do: true

  defp result_key(%{fragment: fragment, match: %{node: node}}) do
    {fragment.file, node_line(node), Macro.to_string(node)}
  end

  defp result_key(%{fragment: fragment}), do: {fragment.file, fragment.line, fragment.id}

  defp node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp node_line(_node), do: 0

  defp verifier_name({:pattern, _}), do: :pattern
  defp verifier_name({:selector, _}), do: :selector
  defp verifier_name(nil), do: nil
end
