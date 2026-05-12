defmodule Exograph.Symbols do
  @moduledoc false

  @type result :: %{
          defs: MapSet.t(String.t()),
          refs: MapSet.t(String.t()),
          modules: MapSet.t(String.t()),
          functions: MapSet.t(String.t()),
          aliases: MapSet.t(String.t()),
          structs: MapSet.t(String.t()),
          atoms: MapSet.t(String.t())
        }

  @spec extract(Macro.t()) :: result()
  def extract(ast) do
    {_ast, acc} = Macro.prewalk(ast, empty(), &visit/2)
    acc
  end

  defp empty do
    %{
      defs: MapSet.new(),
      refs: MapSet.new(),
      modules: MapSet.new(),
      functions: MapSet.new(),
      aliases: MapSet.new(),
      structs: MapSet.new(),
      atoms: MapSet.new()
    }
  end

  defp visit({:defmodule, _, [module_ast | _]} = node, acc) do
    case alias_name(module_ast) do
      nil -> {node, acc}
      module -> {node, acc |> put(:defs, module) |> put(:modules, module)}
    end
  end

  defp visit({form, _, [head | _]} = node, acc)
       when form in [:def, :defp, :defmacro, :defmacrop] do
    case function_head(head) do
      {name, arity} ->
        {node, acc |> put(:defs, "#{name}/#{arity}") |> put(:functions, Atom.to_string(name))}

      nil ->
        {node, acc}
    end
  end

  defp visit({:alias, _, args} = node, acc) when is_list(args) do
    aliases = args |> List.flatten() |> Enum.flat_map(&aliases_from/1)
    {node, Enum.reduce(aliases, acc, &put(&2, :aliases, &1))}
  end

  defp visit({:%, _, [struct_ast | _]} = node, acc) do
    case alias_name(struct_ast) do
      nil -> {node, acc}
      struct -> {node, put(acc, :structs, struct)}
    end
  end

  defp visit({{:., _, [module_ast, fun]}, _, args} = node, acc)
       when is_atom(fun) and is_list(args) do
    case alias_name(module_ast) do
      nil -> {node, put(acc, :refs, "#{fun}/#{length(args)}")}
      module -> {node, put(acc, :refs, "#{module}.#{fun}/#{length(args)}")}
    end
  end

  defp visit({name, _, args} = node, acc) when is_atom(name) and is_list(args) do
    if name in [:__aliases__, :., :..., :_] do
      {node, acc}
    else
      {node, put(acc, :refs, "#{name}/#{length(args)}")}
    end
  end

  defp visit({:__aliases__, _, _} = node, acc) do
    case alias_name(node) do
      nil -> {node, acc}
      alias -> {node, put(acc, :aliases, alias)}
    end
  end

  defp visit(atom, acc) when is_atom(atom) and atom not in [nil, true, false] do
    {atom, put(acc, :atoms, Atom.to_string(atom))}
  end

  defp visit(node, acc), do: {node, acc}

  defp function_head({:when, _, [head | _]}), do: function_head(head)
  defp function_head({name, _, nil}) when is_atom(name), do: {name, 0}

  defp function_head({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp function_head(_), do: nil

  defp aliases_from({:__aliases__, _, _} = ast), do: [alias_name(ast)]

  defp aliases_from({{:., _, [base, :{}]}, _, grouped}) when is_list(grouped) do
    base = alias_name(base)

    if base do
      Enum.flat_map(grouped, fn item ->
        case alias_name(item) do
          nil -> []
          suffix -> [base <> "." <> suffix]
        end
      end)
    else
      []
    end
  end

  defp aliases_from(_), do: []

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Enum.join(parts, "."), else: nil
  end

  defp alias_name(_), do: nil

  defp put(acc, _key, nil), do: acc

  defp put(acc, key, value) when is_binary(value),
    do: Map.update!(acc, key, &MapSet.put(&1, value))
end
