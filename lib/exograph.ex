defmodule Exograph do
  @moduledoc """
  Local CodeQL-style code search for Elixir, backed by Postgres and ExAST.

  ## Quick start

      {:ok, index} = Exograph.index("lib", repo: MyApp.Repo, migrate?: true)
      {:ok, hits} = Exograph.search(index, "Repo.get!(_, _)")

  ## DSL queries

      import Exograph.DSL
      query = from(f in Fragment, where: matches(f, "def _ do ... end"))
      {:ok, hits} = Exograph.all(index, query)

  ## Call graph

      {:ok, callers} = Exograph.search_callers(index, "Repo.transaction/1")
      {:ok, callees} = Exograph.search_callees(index, "MyApp.create_user/1")
  """

  alias Exograph.{
    CommentHit,
    DefinitionHit,
    DSL,
    Hit,
    Index,
    ReferenceHit,
    Similarity,
    StructuralQuery,
    Text,
    TextHit
  }

  alias Exograph.Extractor.ExAST, as: ExASTExtractor
  alias Exograph.Postgres.FragmentStore, as: PostgresFragmentStore
  alias Exograph.Postgres.InvertedIndex, as: PostgresInvertedIndex
  alias Exograph.Postgres.TreeStore, as: PostgresTreeStore

  @spec index(String.t() | [String.t()], keyword()) :: {:ok, Index.t()} | {:error, term()}
  def index(paths, opts \\ []) do
    opts = normalize_backend(opts)
    do_index(ExASTExtractor.stream_paths(paths, extractor_opts(opts)), opts)
  end

  @doc false
  def index_sources(sources, opts \\ []) do
    opts = normalize_backend(opts)
    do_index(ExASTExtractor.stream_sources(sources, extractor_opts(opts)), opts)
  end

  defp do_index(fragments, opts) do
    store_opts = store_opts(opts)

    store_opts =
      if opts[:backend] == :duckdb do
        Exograph.DuckDB.configure_threads!(
          Keyword.fetch!(opts, :repo),
          Keyword.get(opts, :duckdb_threads)
        )

        if Keyword.get(opts, :migrate?, false), do: Exograph.DuckDB.migrate!(opts)
        Keyword.put(store_opts, :migrate?, false)
      else
        store_opts
      end

    store_opts_without_migration = Keyword.put(store_opts, :migrate?, false)
    batch_size = Keyword.get(opts, :index_batch_size, 2_000)

    with {:ok, inverted} <- PostgresInvertedIndex.new(store_opts),
         {:ok, fragment_store} <- PostgresFragmentStore.new(store_opts_without_migration),
         {:ok, tree_store} <- PostgresTreeStore.new(store_opts_without_migration),
         {:ok, {inverted, fragment_store, tree_store}} <-
           put_fragment_stream(fragments, batch_size, inverted, fragment_store, tree_store) do
      {:ok,
       %Index{
         inverted: inverted,
         fragment_store: fragment_store,
         tree_store: tree_store
       }}
    end
  end

  @spec search(Index.t() | term(), ExAST.Pattern.pattern() | ExAST.Selector.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search(index, pattern_or_selector, opts \\ [])

  def search(%Index{} = index, pattern_or_selector, opts) do
    compiled = compile(pattern_or_selector)
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    hits =
      index
      |> DSL.Executor.stream_structural(compiled, opts)
      |> Stream.flat_map(fn fragment ->
        case StructuralQuery.verify(compiled, fragment) do
          {:ok, matches} ->
            Enum.map(matches, &Hit.with_match(Hit.new(fragment: fragment, score: 1.0), &1))

          :error ->
            []
        end
      end)
      |> Stream.drop(skip)
      |> Enum.take(limit)

    {:ok, hits}
  end

  def search(_index, _pattern_or_selector, _opts) do
    {:error, :invalid_index}
  end

  @spec all(Index.t(), DSL.Query.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def all(index, query, opts \\ [])

  def all(%Index{} = index, %DSL.Query{source: :fragment} = query, opts) do
    DSL.Executor.all(index, query, opts)
  end

  def all(%Index{} = index, %DSL.Query{} = query, opts) do
    DSL.Executor.all(index, query, opts)
  end

  @spec search_callers(Index.t(), String.t(), keyword()) :: {:ok, [Exograph.CallEdge.t()]}
  def search_callers(%Index{} = index, callee, opts \\ []) when is_binary(callee) do
    PostgresInvertedIndex.search_callers(index.inverted, callee, opts)
  end

  @spec search_callees(Index.t(), String.t(), keyword()) :: {:ok, [Exograph.CallEdge.t()]}
  def search_callees(%Index{} = index, caller, opts \\ []) when is_binary(caller) do
    PostgresInvertedIndex.search_callees(index.inverted, caller, opts)
  end

  @doc false
  @spec similar(Index.t(), String.t() | Macro.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def similar(%Index{} = index, source_or_ast, opts \\ []) do
    Similarity.search(index, source_or_ast, opts)
  end

  @doc "Searches source text by literal string or regex."
  @spec search_text(Index.t(), String.t() | Regex.t(), keyword()) :: {:ok, [TextHit.t()]}
  def search_text(index, literal_or_regex, opts \\ [])

  def search_text(%Index{} = index, %Regex{} = regex, opts) do
    {:ok, hits} = PostgresInvertedIndex.search_text_regex(index.inverted, regex, opts)
    typed_hits(hits, TextHit)
  end

  def search_text(%Index{} = index, literal, opts) when is_binary(literal) do
    {:ok, hits} = PostgresInvertedIndex.search_text(index.inverted, literal, opts)

    hits
    |> Enum.filter(&text_match?(&1.fragment.source || "", literal))
    |> typed_hits(TextHit)
  end

  @doc false
  @spec search_comments(Index.t(), String.t(), keyword()) :: {:ok, [CommentHit.t()]}
  def search_comments(%Index{} = index, literal, opts \\ []) when is_binary(literal) do
    {:ok, hits} = PostgresInvertedIndex.search_comments(index.inverted, literal, opts)

    hits
    |> Enum.filter(&text_match?(comments_text(&1.fragment.source), literal))
    |> typed_hits(CommentHit)
  end

  @doc false
  @spec search_definitions(Index.t(), String.t(), keyword()) :: {:ok, [DefinitionHit.t()]}
  def search_definitions(%Index{} = index, partial_name, opts \\ [])
      when is_binary(partial_name) do
    case PostgresInvertedIndex.search_definitions(index.inverted, partial_name, opts) do
      {:ok, hits} -> typed_hits(hits, DefinitionHit)
      {:error, _} -> {:ok, []}
    end
  end

  @doc false
  @spec search_references(Index.t(), String.t(), keyword()) :: {:ok, [ReferenceHit.t()]}
  def search_references(%Index{} = index, partial_name, opts \\ [])
      when is_binary(partial_name) do
    case PostgresInvertedIndex.search_references(index.inverted, partial_name, opts) do
      {:ok, hits} -> typed_hits(hits, ReferenceHit)
      {:error, _} -> {:ok, []}
    end
  end

  @doc false
  @spec compile(ExAST.Pattern.pattern() | ExAST.Selector.t()) :: StructuralQuery.t()
  def compile(%ExAST.Selector{} = selector), do: StructuralQuery.selector(selector)
  def compile(pattern), do: StructuralQuery.pattern(pattern)

  @doc false
  @spec tree_nodes(Index.t(), Exograph.Fragment.id()) :: [Exograph.Tree.Node.t()]
  def tree_nodes(%Index{} = index, fragment_id) do
    PostgresTreeStore.nodes(index.tree_store, fragment_id)
  end

  defp put_fragment_stream(fragments, batch_size, inverted, fragment_store, tree_store) do
    fragments
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, {inverted, fragment_store, tree_store}}, fn batch,
                                                                           {:ok,
                                                                            {inverted,
                                                                             fragment_store,
                                                                             tree_store}} ->
      {:ok, inverted} = PostgresInvertedIndex.add(inverted, batch)
      {:ok, fragment_store} = PostgresFragmentStore.put(fragment_store, batch)
      {:ok, tree_store} = PostgresTreeStore.put_fragments(tree_store, batch)

      {:cont, {:ok, {inverted, fragment_store, tree_store}}}
    end)
  end

  defp normalize_backend(opts) do
    case Keyword.get(opts, :backend, :postgres) do
      nil ->
        Keyword.put(opts, :backend, :postgres)

      :postgres ->
        opts

      "postgres" ->
        Keyword.put(opts, :backend, :postgres)

      :duckdb ->
        opts

      "duckdb" ->
        Keyword.put(opts, :backend, :duckdb)

      other ->
        raise ArgumentError, "unsupported backend #{inspect(other)}; use :postgres or :duckdb"
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

  defp typed_hits(hits, module) do
    {:ok,
     Enum.map(hits, fn
       %{__struct__: ^module} = hit -> hit
       hit -> module.new(fragment: hit.fragment, score: hit.score, match: hit.match)
     end)}
  end

  defp text_match?(source, literal) when is_binary(literal),
    do: Text.literal_match?(source, literal)

  defp comments_text(source) when is_binary(source), do: Exograph.File.comments_text(source)

  defp comments_text(_source), do: ""
end
