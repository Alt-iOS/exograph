defmodule Exograph.Web.Completion do
  @moduledoc false

  import Ecto.Query

  alias Exograph.Postgres.Options

  @sources ~w(Fragment Definition Reference CallEdge)
  @fragment_fields ~w(kind module name arity line end_line mass)
  @definition_fields ~w(kind module name arity qualified_name line)
  @reference_fields ~w(kind module name arity qualified_name line)
  @call_edge_fields ~w(caller_qualified_name callee_qualified_name line)
  @assocs ~w(:definitions :references :calls)
  @predicates ~w(matches contains prefix_search)

  def complete(hint, index) do
    cond do
      String.ends_with?(hint, "in ") ->
        sources()

      String.ends_with?(hint, "assoc(") or String.contains?(hint, "assoc(") ->
        assocs()

      String.match?(hint, ~r/f\.\s*$/) ->
        fields(:fragment)

      String.match?(hint, ~r/d\.\s*$/) ->
        fields(:definition)

      String.match?(hint, ~r/r\.\s*$/) ->
        fields(:reference)

      String.match?(hint, ~r/e\.\s*$/) ->
        fields(:call_edge)

      String.match?(hint, ~r/qualified_name\s*==\s*"[^"]*$/) ->
        partial = extract_string_value(hint)
        suggest_qualified_names(index, partial)

      String.match?(hint, ~r/callee_qualified_name\s*==\s*"[^"]*$/) ->
        partial = extract_string_value(hint)
        suggest_callees(index, partial)

      String.match?(hint, ~r/module\s*==\s*"[^"]*$/) ->
        partial = extract_string_value(hint)
        suggest_modules(index, partial)

      String.match?(hint, ~r/where:\s*\w+$/) ->
        predicates()

      true ->
        []
    end
  end

  defp item(label, kind, detail),
    do: %{label: label, kind: kind, detail: detail, insert_text: label}

  defp sources do
    Enum.map(@sources, fn s -> item(s, "module", "Exograph source") end)
  end

  defp assocs do
    Enum.map(@assocs, fn a -> item(a, "field", "association") end)
  end

  defp fields(:fragment), do: field_items(@fragment_fields)
  defp fields(:definition), do: field_items(@definition_fields)
  defp fields(:reference), do: field_items(@reference_fields)
  defp fields(:call_edge), do: field_items(@call_edge_fields)

  defp field_items(fields) do
    Enum.map(fields, fn f -> item(f, "field", "field") end)
  end

  defp predicates do
    Enum.map(@predicates, fn p -> item(p, "function", "predicate") end)
  end

  defp suggest_qualified_names(index, partial) do
    prefix = index.inverted.prefix

    from(r in Options.references_source(prefix),
      where: ilike(r.qualified_name, ^"#{partial}%"),
      group_by: r.qualified_name,
      order_by: [desc: count()],
      limit: 15,
      select: r.qualified_name
    )
    |> index.inverted.repo.all(timeout: 10_000)
    |> Enum.map(fn name -> item(name, "variable", "reference") end)
  rescue
    _ -> []
  end

  defp suggest_callees(index, partial) do
    prefix = index.inverted.prefix

    from(e in Options.call_edges_source(prefix),
      where: ilike(e.callee_qualified_name, ^"#{partial}%"),
      group_by: e.callee_qualified_name,
      order_by: [desc: count()],
      limit: 15,
      select: e.callee_qualified_name
    )
    |> index.inverted.repo.all(timeout: 10_000)
    |> Enum.map(fn name -> item(name, "variable", "callee") end)
  rescue
    _ -> []
  end

  defp suggest_modules(index, partial) do
    prefix = index.inverted.prefix
    table = Options.fragments_source(prefix)

    from(f in {table, Exograph.Postgres.FragmentRecord},
      where: not is_nil(f.module) and ilike(f.module, ^"#{partial}%"),
      group_by: f.module,
      order_by: [desc: count()],
      limit: 15,
      select: f.module
    )
    |> index.inverted.repo.all(timeout: 10_000)
    |> Enum.map(fn name -> item(name, "module", "module") end)
  rescue
    _ -> []
  end

  defp extract_string_value(hint) do
    case Regex.run(~r/"([^"]*)$/, hint) do
      [_, partial] -> partial
      _ -> ""
    end
  end
end
