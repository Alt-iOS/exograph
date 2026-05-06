defmodule Exograph do
  @moduledoc """
  Structural search and code intelligence for Elixir.
  """

  alias Exograph.{Backend, Index, Indexer, Planner, Query, Similarity, Text}
  alias Exograph.InvertedIndex.Memory, as: MemoryInvertedIndex

  @spec index(String.t() | [String.t()], keyword()) :: {:ok, Index.t()} | {:error, term()}
  def index(paths, opts \\ []) do
    backend_config = Backend.config(opts)
    inverted_backend = Keyword.fetch!(backend_config, :inverted)
    fragment_store_backend = Keyword.fetch!(backend_config, :fragment_store)
    tree_store_backend = Keyword.fetch!(backend_config, :tree_store)
    inverted_opts = Keyword.fetch!(backend_config, :inverted_opts)
    fragment_store_opts = Keyword.fetch!(backend_config, :fragment_store_opts)
    tree_store_opts = Keyword.fetch!(backend_config, :tree_store_opts)

    indexer_opts =
      Keyword.drop(opts, [
        :backend,
        :backend_opts,
        :fragment_store,
        :fragment_store_opts,
        :tree_store,
        :tree_store_opts,
        :repo,
        :prefix,
        :migrate?,
        :bm25?,
        :index_path
      ])

    with fragments <- Indexer.index_paths(paths, indexer_opts),
         {:ok, inverted} <- inverted_backend.new(inverted_opts),
         {:ok, inverted} <- inverted_backend.add(inverted, fragments),
         {:ok, fragment_store} <- fragment_store_backend.new(fragment_store_opts),
         {:ok, fragment_store} <- fragment_store_backend.put(fragment_store, fragments),
         {:ok, tree_store} <- tree_store_backend.new(tree_store_opts),
         {:ok, tree_store} <- tree_store_backend.put_fragments(tree_store, fragments) do
      {:ok,
       %Index{
         inverted_backend: inverted_backend,
         inverted: inverted,
         fragment_store_backend: fragment_store_backend,
         fragment_store: fragment_store,
         tree_store_backend: tree_store_backend,
         tree_store: tree_store
       }}
    end
  end

  @spec search(Index.t() | term(), ExAST.Pattern.pattern() | ExAST.Selector.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search(index, pattern_or_selector, opts \\ [])

  def search(%Index{} = index, pattern_or_selector, opts) do
    query = compile(pattern_or_selector)
    plan = Planner.plan(index, query, opts)
    Planner.execute(index, plan, opts)
  end

  def search(index, pattern_or_selector, opts) do
    backend = Keyword.get(opts, :backend, MemoryInvertedIndex)
    query = compile(pattern_or_selector)
    verify? = Keyword.get(opts, :verify, true)

    with {:ok, hits} <- backend.search(index, query, opts) do
      if verify?, do: {:ok, verify_hits(hits, query)}, else: {:ok, hits}
    end
  end

  @spec similar(Index.t(), String.t() | Macro.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def similar(%Index{} = index, source_or_ast, opts \\ []) do
    Similarity.search(index, source_or_ast, opts)
  end

  @spec search_text(Index.t(), String.t() | Regex.t(), keyword()) :: {:ok, [map()]}
  def search_text(%Index{} = index, literal_or_regex, opts \\ []) do
    if is_binary(literal_or_regex) and function_exported?(index.inverted_backend, :search_text, 3) do
      case index.inverted_backend.search_text(index.inverted, literal_or_regex, opts) do
        {:ok, hits} ->
          {:ok, Enum.filter(hits, &text_match?(&1.fragment.source || "", literal_or_regex))}

        {:error, _reason} ->
          search_text_seq(index, literal_or_regex, opts)
      end
    else
      search_text_seq(index, literal_or_regex, opts)
    end
  end

  @spec compile(ExAST.Pattern.pattern() | ExAST.Selector.t()) :: Query.t()
  def compile(%ExAST.Selector{} = selector), do: Query.selector(selector)
  def compile(pattern), do: Query.pattern(pattern)

  @spec plan(Index.t(), ExAST.Pattern.pattern() | ExAST.Selector.t() | Query.t(), keyword()) ::
          Exograph.Planner.Plan.t()
  def plan(index, pattern_or_selector, opts \\ [])
  def plan(%Index{} = index, %Query{} = query, opts), do: Planner.plan(index, query, opts)

  def plan(%Index{} = index, pattern_or_selector, opts),
    do: Planner.plan(index, compile(pattern_or_selector), opts)

  @spec explain(
          ExAST.Pattern.pattern()
          | ExAST.Selector.t()
          | Query.t()
          | Exograph.Planner.Plan.t()
        ) :: map()
  def explain(%Exograph.Planner.Plan{} = plan), do: Planner.explain(plan)

  def explain(%Query{} = query) do
    %{
      required: query.required_terms |> MapSet.to_list() |> Enum.sort(),
      optional: query.optional_terms |> MapSet.to_list() |> Enum.sort(),
      negative: query.negative_terms |> MapSet.to_list() |> Enum.sort(),
      candidate_groups:
        Enum.map(query.candidate_groups, fn group -> group |> MapSet.to_list() |> Enum.sort() end),
      verifier: verifier_name(query.verifier)
    }
  end

  def explain(pattern_or_selector), do: pattern_or_selector |> compile() |> explain()

  @spec tree_nodes(Index.t(), Exograph.Fragment.id()) :: [Exograph.Tree.Node.t()]
  def tree_nodes(%Index{} = index, fragment_id) do
    index.tree_store_backend.nodes(index.tree_store, fragment_id)
  end

  defp search_text_seq(%Index{} = index, literal_or_regex, opts) do
    limit = Keyword.get(opts, :limit, 50)

    query_trigrams =
      if is_binary(literal_or_regex), do: Text.trigrams(literal_or_regex), else: MapSet.new()

    results =
      index.fragment_store_backend.all(index.fragment_store)
      |> Enum.filter(fn fragment ->
        source = fragment.source || ""

        trigram_candidate? =
          MapSet.size(query_trigrams) == 0 or
            MapSet.subset?(query_trigrams, Text.trigrams(source))

        trigram_candidate? and text_match?(source, literal_or_regex)
      end)
      |> Enum.map(&%{fragment: &1, score: 1.0, matched_terms: []})
      |> Enum.take(limit)

    {:ok, results}
  end

  defp verify_hits(hits, query) do
    Enum.flat_map(hits, fn hit ->
      case Query.verify(query, hit.fragment) do
        {:ok, matches} -> Enum.map(matches, &Map.merge(hit, %{match: &1}))
        :error -> []
      end
    end)
  end

  defp text_match?(source, literal) when is_binary(literal),
    do: Text.literal_match?(source, literal)

  defp text_match?(source, %Regex{} = regex), do: Text.regex_match?(source, regex)

  defp verifier_name({:pattern, _}), do: :pattern
  defp verifier_name({:selector, _}), do: :selector
  defp verifier_name(nil), do: nil
end
