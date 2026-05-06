defmodule Mix.Tasks.Exograph.Search do
  use Mix.Task

  @shortdoc "Searches an Elixir codebase with Exograph"

  @moduledoc """
  Searches Elixir source files with Exograph.

      mix exograph.search 'Repo.get!(_, _)'
      mix exograph.search 'def _ do ... end' lib --contains 'Repo.transaction(_)'
      mix exograph.search 'def _ do ... end' lib --contains 'Repo.transaction(_)' --not-contains 'IO.inspect(_)'
      mix exograph.search 'Repo.get!(_, _)' lib --backend postgres --repo MyApp.Repo --migrate
      mix exograph.search 'Repo.get!(_, _)' lib --backend tantivy --index-path .exograph/search
      mix exograph.search 'Repo.get!(_, _)' lib --explain
      mix exograph.search '/users/:id' lib --text
      mix exograph.search 'Repo\\.get!\\(' lib --regex

  ## Options

    * `--backend` - `memory`, `postgres`, or `tantivy` (default: `memory`)
    * `--repo` - Ecto repo module for the Postgres backend
    * `--prefix` - Exograph table prefix for the Postgres backend (default: `exograph`)
    * `--migrate` - create/upgrade Postgres tables and ParadeDB BM25 index
    * `--no-bm25` - skip ParadeDB `pg_search` extension/index creation during migration
    * `--index-path` - Tantivy index directory (default: `.exograph/search`)
    * `--min-mass` - minimum AST fragment mass (default: `8`)
    * `--limit` - maximum results (default: `20`)
    * `--contains` - require descendant pattern, can be repeated
    * `--not-contains` - reject descendant pattern, can be repeated; verifier-only
    * `--explain` - print the query plan before results
    * `--no-verify` - skip final ExAST verification
    * `--json` - print JSON results
    * `--text` - literal source text search instead of AST query
    * `--regex` - regex source text search instead of AST query
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          backend: :string,
          index_path: :string,
          repo: :string,
          prefix: :string,
          migrate: :boolean,
          no_bm25: :boolean,
          min_mass: :integer,
          limit: :integer,
          contains: :keep,
          not_contains: :keep,
          explain: :boolean,
          no_verify: :boolean,
          json: :boolean,
          text: :boolean,
          regex: :boolean
        ],
        aliases: [b: :backend, o: :index_path, n: :limit]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    case positional do
      [] ->
        Mix.raise("Expected a query pattern or text. See `mix help exograph.search`.")

      [query | paths] ->
        run_search(query, if(paths == [], do: ["lib"], else: paths), opts)
    end
  end

  defp run_search(query_text, paths, opts) do
    backend_name = Keyword.get(opts, :backend, "memory")
    min_mass = Keyword.get(opts, :min_mass, 8)
    limit = Keyword.get(opts, :limit, 20)
    {backend, backend_opts} = backend(backend_name, opts)

    {:ok, index} =
      Exograph.index(paths, index_opts(backend, backend_opts, min_mass))

    cond do
      Keyword.get(opts, :text, false) ->
        {:ok, results} = Exograph.search_text(index, query_text, limit: limit)
        print_results(results, opts)

      Keyword.get(opts, :regex, false) ->
        {:ok, regex} = Regex.compile(query_text)
        {:ok, results} = Exograph.search_text(index, regex, limit: limit)
        print_results(results, opts)

      true ->
        query = ast_query(query_text, opts)

        plan =
          Exograph.plan(index, query, limit: limit, verify: !Keyword.get(opts, :no_verify, false))

        if Keyword.get(opts, :explain, false) do
          print_explain(plan, opts)
        end

        {:ok, results} =
          Exograph.search(index, query,
            limit: limit,
            verify: !Keyword.get(opts, :no_verify, false)
          )

        print_results(results, opts)
    end
  end

  defp ast_query(pattern, opts) do
    contains = Keyword.get_values(opts, :contains)
    not_contains = Keyword.get_values(opts, :not_contains)

    if contains == [] and not_contains == [] do
      pattern
    else
      selector = ExAST.Selector.from(pattern)

      selector =
        Enum.reduce(contains, selector, fn pattern, selector ->
          ExAST.Selector.where_predicate(selector, ExAST.Selector.contains(pattern))
        end)

      Enum.reduce(not_contains, selector, fn pattern, selector ->
        ExAST.Selector.where_predicate(
          selector,
          ExAST.Selector.contains(pattern) |> ExAST.Selector.not()
        )
      end)
    end
  end

  defp index_opts(Exograph.InvertedIndex.Postgres, backend_opts, min_mass) do
    [
      backend: Exograph.InvertedIndex.Postgres,
      backend_opts: backend_opts,
      fragment_store: Exograph.FragmentStore.Postgres,
      fragment_store_opts: Keyword.put(backend_opts, :migrate?, false),
      tree_store: Exograph.TreeStore.Postgres,
      tree_store_opts: Keyword.put(backend_opts, :migrate?, false),
      min_mass: min_mass
    ]
  end

  defp index_opts(backend, backend_opts, min_mass) do
    [backend: backend, backend_opts: backend_opts, min_mass: min_mass]
  end

  defp backend("memory", _opts), do: {Exograph.InvertedIndex.Memory, []}

  defp backend("postgres", opts) do
    repo = repo!(opts)

    {Exograph.InvertedIndex.Postgres,
     [
       repo: repo,
       prefix: Keyword.get(opts, :prefix, "exograph"),
       migrate?: Keyword.get(opts, :migrate, false),
       bm25?: !Keyword.get(opts, :no_bm25, false)
     ]}
  end

  defp backend("tantivy", opts) do
    path = Keyword.get(opts, :index_path, ".exograph/search")
    {Exograph.InvertedIndex.TantivyEx, [path: path]}
  end

  defp backend(other, _opts) do
    Mix.raise("Unknown backend #{inspect(other)}. Expected: memory, postgres, or tantivy")
  end

  defp repo!(opts) do
    opts
    |> Keyword.fetch!(:repo)
    |> String.split(".")
    |> Module.concat()
  end

  defp print_explain(plan, opts) do
    explain = Exograph.explain(plan)

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(json(%{plan: explain}))
    else
      Mix.shell().info("Plan: #{inspect(explain, pretty: true, limit: :infinity)}")
    end
  end

  defp print_results(results, opts) do
    if Keyword.get(opts, :json, false) do
      Mix.shell().info(json(%{results: Enum.map(results, &result_json/1)}))
    else
      Mix.shell().info("#{length(results)} result(s)")
      Enum.each(results, &print_result/1)
    end
  end

  defp print_result(%{fragment: fragment} = result) do
    {line, label} = result_label(result)
    score = Map.get(result, :score, 0.0)

    Mix.shell().info("#{fragment.file}:#{line} #{label} score=#{Float.round(score * 1.0, 3)}")
  end

  defp result_label(%{match: %{node: node}}), do: node_label(node)

  defp result_label(%{fragment: fragment}) do
    label = [fragment.kind, fragment.name || ""] |> Enum.join(" ") |> String.trim()
    {fragment.line, label}
  end

  defp node_label({form, meta, [head | _]}) when form in [:def, :defp, :defmacro, :defmacrop] do
    case unwrap_head(head) do
      {name, _, args} when is_atom(name) and is_list(args) ->
        {Keyword.get(meta, :line, 0), "#{form} #{name}/#{length(args)}"}

      {name, _, nil} when is_atom(name) ->
        {Keyword.get(meta, :line, 0), "#{form} #{name}/0"}

      _ ->
        {Keyword.get(meta, :line, 0), Atom.to_string(form)}
    end
  end

  defp node_label({form, meta, _args}) when is_atom(form),
    do: {Keyword.get(meta, :line, 0), Atom.to_string(form)}

  defp node_label(_node), do: {0, "match"}

  defp unwrap_head({:when, _, [head | _]}), do: unwrap_head(head)
  defp unwrap_head(head), do: head

  defp result_json(%{fragment: fragment} = result) do
    %{
      file: fragment.file,
      line: fragment.line,
      kind: fragment.kind,
      name: fragment.name,
      score: Map.get(result, :score, 0.0)
    }
  end

  defp json(value), do: Jason.encode!(value)
end
