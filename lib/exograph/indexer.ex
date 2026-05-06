defmodule Exograph.Indexer do
  @moduledoc """
  Builds Exograph fragments from Elixir source files.
  """

  alias ExDNA.AST.{Fingerprint, Normalizer}
  alias Exograph.AST.Terms
  alias Exograph.{Fragment, Symbols}

  @default_opts [min_mass: 15, literal_mode: :keep, normalize_pipes: true]

  @spec index_paths(String.t() | [String.t()], keyword()) :: [Fragment.t()]
  def index_paths(paths, opts \\ []) do
    paths
    |> List.wrap()
    |> Enum.flat_map(&expand_path/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Task.async_stream(&index_file(&1, opts),
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, fragments} -> fragments
      {:exit, _reason} -> []
    end)
  end

  @spec index_file(String.t(), keyword()) :: [Fragment.t()]
  def index_file(file, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, line: 1, columns: true, file: file) do
      ast
      |> Fingerprint.fragments(file, Keyword.fetch!(opts, :min_mass), opts)
      |> Enum.map(&to_fragment(&1, source))
    else
      _ -> []
    end
  end

  defp to_fragment(fingerprint, source) do
    ast = fingerprint.ast
    {kind, name, arity} = classify(ast)
    line = Map.get(fingerprint, :line, line(ast))
    exact_hash = fingerprint.hash

    abstract_hash =
      ast |> Normalizer.normalize(literal_mode: :abstract) |> Fingerprint.compute_hash()

    terms = Terms.from_source(ast)
    symbols = Symbols.extract(ast)

    %Fragment{
      id: fragment_id(fingerprint.file, line, exact_hash),
      file: fingerprint.file,
      source: source,
      ast: ast,
      kind: kind,
      name: name,
      arity: arity,
      line: line,
      mass: fingerprint.mass,
      exact_hash: exact_hash,
      abstract_hash: abstract_hash,
      terms: terms,
      sub_hashes: fingerprint.sub_hashes,
      defs: symbols.defs,
      refs: symbols.refs,
      modules: symbols.modules,
      functions: symbols.functions,
      aliases: symbols.aliases,
      structs: symbols.structs,
      atoms: symbols.atoms
    }
  end

  defp classify({form, _meta, [head | _]}) when form in [:def, :defp, :defmacro, :defmacrop] do
    case unwrap_head(head) do
      {name, _, nil} when is_atom(name) ->
        {form, Atom.to_string(name), 0}

      {name, _, args} when is_atom(name) and is_list(args) ->
        {form, Atom.to_string(name), length(args)}

      _ ->
        {form, nil, nil}
    end
  end

  defp classify({:defmodule, _meta, [module_ast | _]}) do
    {:module, alias_name(module_ast), nil}
  end

  defp classify(_ast), do: {:expression, nil, nil}

  defp unwrap_head({:when, _, [head | _]}), do: unwrap_head(head)
  defp unwrap_head(head), do: head

  defp alias_name({:__aliases__, _, parts}), do: Enum.join(parts, ".")
  defp alias_name(_), do: nil

  defp line({_form, meta, _args}), do: Keyword.get(meta, :line, 0)
  defp line(_), do: 0

  defp fragment_id(file, line, hash) do
    :crypto.hash(:blake2b, :erlang.term_to_binary({file, line, hash}))
    |> Base.encode16(case: :lower)
  end

  defp expand_path(path) do
    cond do
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
      String.contains?(path, "*") -> Path.wildcard(path)
      File.regular?(path) -> [path]
      true -> []
    end
  end
end
