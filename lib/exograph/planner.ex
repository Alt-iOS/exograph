defmodule Exograph.Planner do
  @moduledoc """
  Query planner and executor.

  Indexes are advisory: every plan preserves `ExAST` semantics by hydrating
  fragments and running the exact verifier unless verification is explicitly
  disabled.
  """

  alias Exograph.Planner.{LogicalPlan, PhysicalPlan, Plan, Stats}
  alias Exograph.{Index, Query}

  @spec plan(Index.t(), Query.t(), keyword()) :: Plan.t()
  def plan(%Index{} = index, %Query{} = query, opts \\ []) do
    stats = Keyword.get_lazy(opts, :stats, fn -> Stats.collect(index) end)
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
          verify_hits(hits, plan.query)
        else
          hits
        end

      {:ok, Enum.take(results, plan.physical.limit)}
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
    groups
    |> Enum.map(&Stats.estimate_terms(stats, &1))
    |> Enum.reduce(0, fn
      :unknown, _acc -> :unknown
      _estimate, :unknown -> :unknown
      estimate, acc -> estimate + acc
    end)
  end

  defp filters(false), do: [:hydrate_fragments]
  defp filters(true), do: [:hydrate_fragments, :ex_ast_verify]

  defp scan(index, %Plan{physical: %PhysicalPlan{scan: :fragment_seq_scan} = physical}, _opts) do
    hits =
      index.fragment_store_backend.all(index.fragment_store)
      |> Enum.map(&%{fragment: &1, score: 1.0, matched_terms: []})
      |> maybe_take_candidates(physical)

    {:ok, hits}
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
        {:ok, hits} -> {:cont, {:ok, acc ++ hits}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hits} ->
        {:ok, Enum.uniq_by(hits, &hit_key/1)}

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
    Keyword.put(opts, :limit, candidate_count(index))
  end

  defp maybe_take_candidates(hits, %PhysicalPlan{verify?: true}), do: hits

  defp maybe_take_candidates(hits, %PhysicalPlan{verify?: false, limit: limit}),
    do: Enum.take(hits, limit)

  defp candidate_count(index) do
    index.fragment_store_backend.all(index.fragment_store) |> length()
  end

  defp hit_key(%{fragment_id: fragment_id}), do: fragment_id
  defp hit_key(%{fragment: fragment}), do: fragment.id

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

  defp hydrate_hit(_index, %{fragment: _fragment} = hit), do: {:ok, hit}

  defp hydrate_hit(index, %{fragment_id: fragment_id} = hit) do
    case index.fragment_store_backend.get(index.fragment_store, fragment_id) do
      {:ok, fragment} -> {:ok, Map.put(hit, :fragment, fragment)}
      :error -> :error
    end
  end

  defp verify_hits(hits, query) do
    hits
    |> Enum.flat_map(fn hit ->
      case Query.verify(query, hit.fragment.ast) do
        {:ok, matches} -> Enum.map(matches, &Map.merge(hit, %{match: &1}))
        :error -> []
      end
    end)
    |> Enum.uniq_by(&result_key/1)
  end

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
