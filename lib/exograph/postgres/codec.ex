defmodule Exograph.Postgres.Codec do
  @moduledoc false

  alias Exograph.Fragment
  alias Exograph.Tree.Node

  @fragment_columns [
    "id",
    "file",
    "source",
    "ast",
    "kind",
    "module",
    "name",
    "arity",
    "line",
    "end_line",
    "mass",
    "exact_hash",
    "abstract_hash",
    "terms",
    "terms_text",
    "sub_hashes",
    "defs",
    "defs_text",
    "refs",
    "refs_text",
    "modules",
    "modules_text",
    "functions",
    "functions_text",
    "aliases",
    "aliases_text",
    "structs",
    "structs_text",
    "atoms",
    "atoms_text"
  ]

  @node_columns [
    "fragment_id",
    "id",
    "parent_id",
    "ordinal",
    "role",
    "kind",
    "label",
    "line",
    "preorder",
    "postorder",
    "depth"
  ]

  def fragment_columns, do: @fragment_columns
  def node_columns, do: @node_columns

  def fragment_params(%Fragment{} = fragment) do
    [
      fragment.id,
      fragment.file,
      fragment.source,
      :erlang.term_to_binary(fragment.ast),
      Atom.to_string(fragment.kind),
      fragment.module,
      fragment.name,
      fragment.arity,
      fragment.line,
      fragment.end_line,
      fragment.mass,
      fragment.exact_hash,
      fragment.abstract_hash,
      strings(fragment.terms),
      joined(fragment.terms),
      fragment.sub_hashes |> MapSet.to_list() |> Enum.map(&to_int64/1),
      strings(fragment.defs),
      joined(fragment.defs),
      strings(fragment.refs),
      joined(fragment.refs),
      strings(fragment.modules),
      joined(fragment.modules),
      strings(fragment.functions),
      joined(fragment.functions),
      strings(fragment.aliases),
      joined(fragment.aliases),
      strings(fragment.structs),
      joined(fragment.structs),
      strings(fragment.atoms),
      joined(fragment.atoms)
    ]
  end

  def node_params(%Node{} = node) do
    [
      node.fragment_id,
      node.id,
      node.parent_id,
      node.ordinal,
      stringify(node.role),
      Atom.to_string(node.kind),
      node.label,
      node.line,
      node.preorder,
      node.postorder,
      node.depth
    ]
  end

  def row_to_fragment(columns, row) do
    values = columns |> Enum.zip(row) |> Map.new()

    %Fragment{
      id: values["id"],
      file: values["file"],
      source: values["source"],
      ast: :erlang.binary_to_term(values["ast"]),
      kind: atomize(values["kind"]),
      module: values["module"],
      name: values["name"],
      arity: values["arity"],
      line: values["line"],
      end_line: values["end_line"],
      mass: values["mass"],
      exact_hash: values["exact_hash"],
      abstract_hash: values["abstract_hash"],
      terms: mapset(values["terms"]),
      sub_hashes: values["sub_hashes"] |> List.wrap() |> MapSet.new(),
      defs: mapset(values["defs"]),
      refs: mapset(values["refs"]),
      modules: mapset(values["modules"]),
      functions: mapset(values["functions"]),
      aliases: mapset(values["aliases"]),
      structs: mapset(values["structs"]),
      atoms: mapset(values["atoms"])
    }
  end

  def row_to_node(columns, row) do
    values = columns |> Enum.zip(row) |> Map.new()

    %Node{
      fragment_id: values["fragment_id"],
      id: values["id"],
      parent_id: values["parent_id"],
      ordinal: values["ordinal"],
      role: atomize(values["role"]),
      kind: atomize(values["kind"]),
      label: values["label"],
      line: values["line"],
      preorder: values["preorder"],
      postorder: values["postorder"],
      depth: values["depth"]
    }
  end

  def placeholders(count, offset \\ 1) do
    offset..(offset + count - 1)
    |> Enum.map_join(", ", &"$#{&1}")
  end

  defp strings(set), do: set |> MapSet.to_list() |> Enum.sort()
  defp joined(set), do: set |> strings() |> Enum.join(" ")
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
  defp atomize(nil), do: nil
  defp atomize(value), do: String.to_existing_atom(value)
  defp mapset(nil), do: MapSet.new()
  defp mapset(values), do: MapSet.new(values)
  defp to_int64(value) when is_integer(value), do: value
end
