defmodule Exograph.Tree do
  @moduledoc false

  alias Exograph.Fragment
  alias Exograph.Tree.Node

  @spec nodes([Fragment.t()] | Fragment.t()) :: [Node.t()]
  def nodes(%Fragment{} = fragment), do: nodes([fragment])

  def nodes(fragments) when is_list(fragments) do
    fragments
    |> Enum.flat_map(fn fragment ->
      {_counter, nodes, _postorder} = walk(fragment.ast, fragment.id, nil, 0, 0, nil, 0, [])
      Enum.reverse(nodes)
    end)
  end

  defp walk(ast, fragment_id, parent_id, ordinal, depth, role, counter, acc) do
    id = counter
    preorder = counter

    {next_counter, acc, _child_ordinal} =
      ast
      |> semantic_children()
      |> Stream.with_index()
      |> Enum.reduce({counter + 1, acc, 0}, fn {{child_role, child}, child_ordinal},
                                               {ctr, nodes, _} ->
        {ctr, nodes, _postorder} =
          walk(child, fragment_id, id, child_ordinal, depth + 1, child_role, ctr, nodes)

        {ctr, nodes, child_ordinal + 1}
      end)

    postorder = next_counter

    node = %Node{
      id: id,
      fragment_id: fragment_id,
      parent_id: parent_id,
      ordinal: ordinal,
      role: role,
      kind: kind(ast),
      label: label(ast),
      line: line(ast),
      preorder: preorder,
      postorder: postorder,
      depth: depth
    }

    {next_counter + 1, [node | acc], postorder}
  end

  defp semantic_children({:__block__, _meta, children}) when is_list(children) do
    Enum.map(children, &{:block_child, &1})
  end

  defp semantic_children({_form, _meta, args}) when is_list(args) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, index} ->
      case arg do
        [{role, {:__block__, _, children}}] when is_atom(role) and is_list(children) ->
          Enum.map(children, &{role, &1})

        [{role, child}] when is_atom(role) and (is_tuple(child) or is_list(child)) ->
          [{role, child}]

        child when is_tuple(child) or is_list(child) ->
          [{String.to_atom("arg#{index}"), child}]

        _ ->
          []
      end
    end)
  end

  defp semantic_children({left, right}), do: [left: left, right: right]

  defp semantic_children(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.filter(fn {child, _} -> is_tuple(child) or is_list(child) end)
    |> Enum.map(fn {child, index} -> {String.to_atom("item#{index}"), child} end)
  end

  defp semantic_children(_), do: []

  defp kind({form, _, _}) when is_atom(form), do: form
  defp kind({_, _}), do: :tuple
  defp kind(list) when is_list(list), do: :list
  defp kind(atom) when is_atom(atom), do: :atom
  defp kind(binary) when is_binary(binary), do: :string
  defp kind(integer) when is_integer(integer), do: :integer
  defp kind(_), do: :literal

  defp label({{:., _, [module_ast, fun]}, _, args}) when is_atom(fun) and is_list(args) do
    module =
      case module_ast do
        {:__aliases__, _, parts} -> if Enum.all?(parts, &is_atom/1), do: Enum.join(parts, ".")
        _ -> nil
      end

    if module, do: "#{module}.#{fun}/#{length(args)}", else: "#{fun}/#{length(args)}"
  end

  defp label({name, _, args}) when is_atom(name) and is_list(args), do: "#{name}/#{length(args)}"

  defp label({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Enum.join(parts, "."), else: nil
  end

  defp label(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp label(binary) when is_binary(binary), do: binary
  defp label(_), do: nil

  defp line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_), do: 0
end
