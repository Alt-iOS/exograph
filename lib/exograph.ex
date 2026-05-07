defmodule Exograph do
  @moduledoc """
  Structural search and code intelligence for Elixir.
  """

  alias Exograph.{
    CommentHit,
    DefinitionHit,
    Index,
    Planner,
    Query,
    ReferenceHit,
    Scope,
    Similarity,
    Text,
    TextHit
  }

  alias Exograph.Extractor.ExAST, as: ExASTExtractor
  alias Exograph.FragmentStore.Postgres, as: PostgresFragmentStore
  alias Exograph.InvertedIndex.Postgres, as: PostgresInvertedIndex
  alias Exograph.TreeStore.Postgres, as: PostgresTreeStore

  @spec index(String.t() | [String.t()], keyword()) :: {:ok, Index.t()} | {:error, term()}
  def index(paths, opts \\ []) do
    opts = normalize_backend(opts)
    indexer_opts = extractor_opts(opts)
    store_opts = store_opts(opts)
    store_opts_without_migration = Keyword.put(store_opts, :migrate?, false)
    batch_size = Keyword.get(opts, :index_batch_size, 2_000)

    with {:ok, inverted} <- PostgresInvertedIndex.new(store_opts),
         {:ok, fragment_store} <- PostgresFragmentStore.new(store_opts_without_migration),
         {:ok, tree_store} <- PostgresTreeStore.new(store_opts_without_migration),
         {:ok, {inverted, fragment_store, tree_store}} <-
           put_fragment_stream(
             ExASTExtractor.stream_paths(paths, indexer_opts),
             batch_size,
             inverted,
             fragment_store,
             tree_store
           ) do
      {:ok,
       %Index{
         inverted_backend: PostgresInvertedIndex,
         inverted: inverted,
         fragment_store_backend: PostgresFragmentStore,
         fragment_store: fragment_store,
         tree_store_backend: PostgresTreeStore,
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

  def search(_index, _pattern_or_selector, _opts) do
    {:error, :invalid_index}
  end

  @spec similar(Index.t(), String.t() | Macro.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def similar(%Index{} = index, source_or_ast, opts \\ []) do
    Similarity.search(index, source_or_ast, opts)
  end

  @spec search_text(Index.t(), String.t() | Regex.t(), keyword()) :: {:ok, [TextHit.t()]}
  def search_text(%Index{} = index, literal_or_regex, opts \\ []) do
    if is_binary(literal_or_regex) and function_exported?(index.inverted_backend, :search_text, 3) do
      case index.inverted_backend.search_text(index.inverted, literal_or_regex, opts) do
        {:ok, hits} ->
          hits
          |> Enum.filter(&text_match?(&1.fragment.source || "", literal_or_regex))
          |> typed_hits(TextHit)

        {:error, _reason} ->
          search_text_seq(index, literal_or_regex, opts)
      end
    else
      search_text_seq(index, literal_or_regex, opts)
    end
  end

  @spec search_comments(Index.t(), String.t(), keyword()) :: {:ok, [CommentHit.t()]}
  def search_comments(%Index{} = index, literal, opts \\ []) when is_binary(literal) do
    if function_exported?(index.inverted_backend, :search_comments, 3) do
      case index.inverted_backend.search_comments(index.inverted, literal, opts) do
        {:ok, hits} ->
          hits
          |> Enum.filter(&text_match?(comments_text(&1.fragment.source), literal))
          |> typed_hits(CommentHit)

        {:error, _reason} ->
          search_comments_seq(index, literal, opts)
      end
    else
      search_comments_seq(index, literal, opts)
    end
  end

  @spec search_definitions(Index.t(), String.t(), keyword()) :: {:ok, [DefinitionHit.t()]}
  def search_definitions(%Index{} = index, partial_name, opts \\ [])
      when is_binary(partial_name) do
    search_code_facts(
      index,
      partial_name,
      opts,
      :search_definitions,
      DefinitionHit,
      &definition_match?/2
    )
  end

  @spec search_references(Index.t(), String.t(), keyword()) :: {:ok, [ReferenceHit.t()]}
  def search_references(%Index{} = index, partial_name, opts \\ [])
      when is_binary(partial_name) do
    search_code_facts(
      index,
      partial_name,
      opts,
      :search_references,
      ReferenceHit,
      &reference_match?/2
    )
  end

  @spec search_callers(Index.t(), String.t(), keyword()) :: {:ok, [Exograph.CallEdge.t()]}
  def search_callers(%Index{} = index, callee, opts \\ []) when is_binary(callee) do
    PostgresInvertedIndex.search_callers(index.inverted, callee, opts)
  end

  @spec search_callees(Index.t(), String.t(), keyword()) :: {:ok, [Exograph.CallEdge.t()]}
  def search_callees(%Index{} = index, caller, opts \\ []) when is_binary(caller) do
    PostgresInvertedIndex.search_callees(index.inverted, caller, opts)
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

  defp put_fragment_stream(fragments, batch_size, inverted, fragment_store, tree_store) do
    fragments
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, {inverted, fragment_store, tree_store}}, fn batch,
                                                                           {:ok,
                                                                            {inverted,
                                                                             fragment_store,
                                                                             tree_store}} ->
      with {:ok, inverted} <- PostgresInvertedIndex.add(inverted, batch),
           {:ok, fragment_store} <- PostgresFragmentStore.put(fragment_store, batch),
           {:ok, tree_store} <- PostgresTreeStore.put_fragments(tree_store, batch) do
        {:cont, {:ok, {inverted, fragment_store, tree_store}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_backend(opts) do
    case Keyword.get(opts, :backend, :postgres) do
      :postgres -> opts
      "postgres" -> Keyword.put(opts, :backend, :postgres)
      other -> raise ArgumentError, "unsupported backend #{inspect(other)}; use :postgres"
    end
  end

  defp extractor_opts(opts) do
    Keyword.drop(opts, [
      :backend,
      :repo,
      :prefix,
      :migrate?,
      :bm25?,
      :index_batch_size,
      :extractors
    ])
  end

  defp store_opts(opts) do
    Keyword.take(opts, [
      :repo,
      :prefix,
      :migrate?,
      :bm25?,
      :package,
      :package_version,
      :extractors
    ])
  end

  defp search_text_seq(%Index{} = index, literal_or_regex, opts) do
    limit = Keyword.get(opts, :limit, 50)

    query_trigrams =
      if is_binary(literal_or_regex), do: Text.trigrams(literal_or_regex), else: MapSet.new()

    index.fragment_store_backend.all(index.fragment_store)
    |> Enum.filter(fn fragment ->
      source = fragment.source || ""

      trigram_candidate? =
        MapSet.size(query_trigrams) == 0 or
          MapSet.subset?(query_trigrams, Text.trigrams(source))

      Scope.fragment?(fragment, opts) and trigram_candidate? and
        text_match?(source, literal_or_regex)
    end)
    |> Enum.map(&TextHit.new(fragment: &1, score: 1.0))
    |> Enum.take(limit)
    |> ok()
  end

  defp search_comments_seq(%Index{} = index, literal, opts) do
    limit = Keyword.get(opts, :limit, 50)

    index.fragment_store_backend.all(index.fragment_store)
    |> Enum.filter(fn fragment ->
      Scope.fragment?(fragment, opts) and text_match?(comments_text(fragment.source), literal)
    end)
    |> Enum.map(&CommentHit.new(fragment: &1, score: 1.0))
    |> Enum.take(limit)
    |> ok()
  end

  defp search_code_facts(index, partial_name, opts, backend_function, hit_module, fallback_match?) do
    if function_exported?(index.inverted_backend, backend_function, 3) do
      case apply(index.inverted_backend, backend_function, [index.inverted, partial_name, opts]) do
        {:ok, hits} ->
          hits
          |> Enum.filter(&fallback_match?.(&1.fragment, partial_name))
          |> typed_hits(hit_module)

        {:error, _reason} ->
          search_code_facts_seq(index, partial_name, opts, hit_module, fallback_match?)
      end
    else
      search_code_facts_seq(index, partial_name, opts, hit_module, fallback_match?)
    end
  end

  defp search_code_facts_seq(%Index{} = index, partial_name, opts, hit_module, fallback_match?) do
    limit = Keyword.get(opts, :limit, 50)

    index.fragment_store_backend.all(index.fragment_store)
    |> Enum.filter(fn fragment ->
      Scope.fragment?(fragment, opts) and fallback_match?.(fragment, partial_name)
    end)
    |> Enum.map(&hit_module.new(fragment: &1, score: 1.0))
    |> Enum.take(limit)
    |> ok()
  end

  defp typed_hits(hits, module) do
    {:ok,
     Enum.map(hits, fn
       %{__struct__: ^module} = hit -> hit
       hit -> module.new(fragment: hit.fragment, score: hit.score, match: hit.match)
     end)}
  end

  defp ok(results), do: {:ok, results}

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
