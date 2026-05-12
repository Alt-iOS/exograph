defmodule Exograph.Extractor.ExAST do
  @moduledoc """
  Extracts ExAST-backed structural fragments from Elixir source files.
  """

  @behaviour Exograph.Extractor

  alias ExDNA.AST.{Fingerprint, Normalizer}
  alias Exograph.{Fragment, Package, PackageVersion, Symbols}
  alias Exograph.File, as: SourceFile

  @default_opts [min_mass: 15, literal_mode: :keep, normalize_pipes: true]

  @impl true
  def index_paths(paths, opts \\ []) do
    paths
    |> stream_paths(opts)
    |> Enum.to_list()
  end

  @impl true
  def stream_paths(paths, opts \\ []) do
    paths
    |> List.wrap()
    |> Enum.flat_map(&expand_path/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Task.async_stream(&index_file(&1, opts),
      max_concurrency: Keyword.get(opts, :index_concurrency, System.schedulers_online()),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.flat_map(fn
      {:ok, fragments} -> fragments
      {:exit, _reason} -> []
    end)
  end

  @spec index_file(String.t(), keyword()) :: [Fragment.t()]
  def index_file(file, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    with {:ok, source} <- File.read(file),
         {:ok, ast} <-
           Code.string_to_quoted(source, line: 1, columns: true, file: file, emit_warnings: false) do
      package_context = package_context(opts)
      source_file = SourceFile.new(file, source, package_context)

      ast
      |> Fingerprint.fragments(file, Keyword.fetch!(opts, :min_mass), opts)
      |> Enum.map(&to_fragment(&1, source_file, package_context))
    else
      _ -> []
    end
  end

  defp to_fragment(fingerprint, source_file, package_context) do
    ast = fingerprint.ast
    {kind, name, arity} = classify(ast)
    line = Map.get(fingerprint, :line, line(ast))
    exact_hash = fingerprint.hash

    abstract_hash =
      ast |> Normalizer.normalize(literal_mode: :abstract) |> Fingerprint.compute_hash()

    terms = ExAST.Index.Terms.from_ast(ast)
    symbols = Symbols.extract(ast)

    content_hash =
      compute_content_hash(package_context.package_version_id, fingerprint.file, line, exact_hash)

    %Fragment{
      id: nil,
      content_hash: content_hash,
      file: fingerprint.file,
      source: source_file.source,
      package_id: package_context.package_id,
      package_version_id: package_context.package_version_id,
      file_id: nil,
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

  defp alias_name({:__aliases__, _, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Enum.join(parts, "."), else: nil
  end

  defp alias_name(_), do: nil

  defp line({_form, meta, _args}), do: Keyword.get(meta, :line, 0)
  defp line(_), do: 0

  defp package_context(opts) do
    cond do
      version_attrs = Keyword.get(opts, :package_version) ->
        version = PackageVersion.new(version_attrs)

        %{
          package_id: version.package_id,
          package_version_id: version.id
        }

      package_attrs = Keyword.get(opts, :package) ->
        package = Package.new(package_attrs)

        %{
          package_id: package.id,
          package_version_id: nil
        }

      true ->
        %{
          package_id: nil,
          package_version_id: nil
        }
    end
  end

  defp compute_content_hash(package_version_id, file, line, hash) do
    :crypto.hash(:blake2b, :erlang.term_to_binary({package_version_id, file, line, hash}))
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
