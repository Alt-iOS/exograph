defmodule Exograph do
  @moduledoc """
  Structural search and code intelligence for Elixir.
  """

  alias Exograph.{Backend, Hit, Index, Indexer, Planner, Query, Scope, Similarity, Text}
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

    if streaming_index?(backend_config) do
      index_stream(paths, backend_config, indexer_opts, opts)
    else
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

  @spec search_comments(Index.t(), String.t(), keyword()) :: {:ok, [map()]}
  def search_comments(%Index{} = index, literal, opts \\ []) when is_binary(literal) do
    if function_exported?(index.inverted_backend, :search_comments, 3) do
      case index.inverted_backend.search_comments(index.inverted, literal, opts) do
        {:ok, hits} ->
          {:ok, Enum.filter(hits, &text_match?(comments_text(&1.fragment.source), literal))}

        {:error, _reason} ->
          search_comments_seq(index, literal, opts)
      end
    else
      search_comments_seq(index, literal, opts)
    end
  end

  @spec search_definitions(Index.t(), String.t(), keyword()) :: {:ok, [map()]}
  def search_definitions(%Index{} = index, partial_name, opts \\ [])
      when is_binary(partial_name) do
    search_code_facts(index, partial_name, opts, :search_definitions, &definition_match?/2)
  end

  @spec search_references(Index.t(), String.t(), keyword()) :: {:ok, [map()]}
  def search_references(%Index{} = index, partial_name, opts \\ [])
      when is_binary(partial_name) do
    search_code_facts(index, partial_name, opts, :search_references, &reference_match?/2)
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

  defp streaming_index?(backend_config) do
    Keyword.fetch!(backend_config, :fragment_store) == Exograph.FragmentStore.Postgres
  end

  defp index_stream(paths, backend_config, indexer_opts, opts) do
    inverted_backend = Keyword.fetch!(backend_config, :inverted)
    fragment_store_backend = Keyword.fetch!(backend_config, :fragment_store)
    tree_store_backend = Keyword.fetch!(backend_config, :tree_store)
    batch_size = Keyword.get(opts, :index_batch_size, 2_000)

    with {:ok, inverted} <- inverted_backend.new(Keyword.fetch!(backend_config, :inverted_opts)),
         {:ok, fragment_store} <-
           fragment_store_backend.new(Keyword.fetch!(backend_config, :fragment_store_opts)),
         {:ok, tree_store} <-
           tree_store_backend.new(Keyword.fetch!(backend_config, :tree_store_opts)),
         {:ok, {inverted, fragment_store, tree_store}} <-
           put_fragment_stream(
             Indexer.stream_paths(paths, indexer_opts),
             batch_size,
             inverted_backend,
             inverted,
             fragment_store_backend,
             fragment_store,
             tree_store_backend,
             tree_store
           ) do
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

  defp put_fragment_stream(
         fragments,
         batch_size,
         inverted_backend,
         inverted,
         fragment_store_backend,
         fragment_store,
         tree_store_backend,
         tree_store
       ) do
    fragments
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, {inverted, fragment_store, tree_store}}, fn batch,
                                                                           {:ok,
                                                                            {inverted,
                                                                             fragment_store,
                                                                             tree_store}} ->
      with {:ok, inverted} <- inverted_backend.add(inverted, batch),
           {:ok, fragment_store} <- fragment_store_backend.put(fragment_store, batch),
           {:ok, tree_store} <- tree_store_backend.put_fragments(tree_store, batch) do
        {:cont, {:ok, {inverted, fragment_store, tree_store}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

        Scope.fragment?(fragment, opts) and trigram_candidate? and
          text_match?(source, literal_or_regex)
      end)
      |> Enum.map(&Hit.new(fragment: &1, score: 1.0))
      |> Enum.take(limit)

    {:ok, results}
  end

  defp search_comments_seq(%Index{} = index, literal, opts) do
    limit = Keyword.get(opts, :limit, 50)

    results =
      index.fragment_store_backend.all(index.fragment_store)
      |> Enum.filter(fn fragment ->
        Scope.fragment?(fragment, opts) and text_match?(comments_text(fragment.source), literal)
      end)
      |> Enum.map(&Hit.new(fragment: &1, score: 1.0))
      |> Enum.take(limit)

    {:ok, results}
  end

  defp search_code_facts(index, partial_name, opts, backend_function, fallback_match?) do
    if function_exported?(index.inverted_backend, backend_function, 3) do
      case apply(index.inverted_backend, backend_function, [index.inverted, partial_name, opts]) do
        {:ok, hits} -> {:ok, Enum.filter(hits, &fallback_match?.(&1.fragment, partial_name))}
        {:error, _reason} -> search_code_facts_seq(index, partial_name, opts, fallback_match?)
      end
    else
      search_code_facts_seq(index, partial_name, opts, fallback_match?)
    end
  end

  defp search_code_facts_seq(%Index{} = index, partial_name, opts, fallback_match?) do
    limit = Keyword.get(opts, :limit, 50)

    results =
      index.fragment_store_backend.all(index.fragment_store)
      |> Enum.filter(fn fragment ->
        Scope.fragment?(fragment, opts) and fallback_match?.(fragment, partial_name)
      end)
      |> Enum.map(&Hit.new(fragment: &1, score: 1.0))
      |> Enum.take(limit)

    {:ok, results}
  end

  defp verify_hits(hits, query) do
    Enum.flat_map(hits, fn hit ->
      case Query.verify(query, hit.fragment) do
        {:ok, matches} -> Enum.map(matches, &Hit.with_match(hit, &1))
        :error -> []
      end
    end)
  end

  defp text_match?(source, literal) when is_binary(literal),
    do: Text.literal_match?(source, literal)

  defp text_match?(source, %Regex{} = regex), do: Text.regex_match?(source, regex)

  defp comments_text(source) when is_binary(source), do: Exograph.File.comments_text(source)

  defp comments_text(_source), do: ""

  defp definition_match?(fragment, partial_name) do
    partial_name = String.downcase(partial_name)

    (fragment.kind in [:def, :defp, :defmacro, :defmacrop] and fragment.name) &&
      String.contains?(String.downcase(fragment.name), partial_name)
  end

  defp reference_match?(fragment, partial_name) do
    partial_name = String.downcase(partial_name)

    Enum.any?(fragment.refs, fn reference ->
      reference |> String.downcase() |> String.contains?(partial_name)
    end)
  end

  defp verifier_name({:pattern, _}), do: :pattern
  defp verifier_name({:selector, _}), do: :selector
  defp verifier_name(nil), do: nil
end
