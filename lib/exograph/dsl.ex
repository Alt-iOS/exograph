defmodule Exograph.DSL do
  @moduledoc """
  Ecto-shaped query DSL for Exograph.

  The DSL currently supports structural `Fragment` queries and relational
  `Definition` / `Reference` queries:

      import Exograph.DSL

      from f in Fragment,
        where: matches(f, "def _ do ... end"),
        where: contains(f, "Repo.transaction(_)")
  """

  alias Exograph.DSL.Query

  defmacro from({:in, _meta, [binding_ast, source_ast]}, clauses) when is_list(clauses) do
    binding = binding_name!(binding_ast)
    source = source!(source_ast, __CALLER__)
    predicates = predicates!(clauses, binding)

    Macro.escape(%Query{source: source, binding: binding, predicates: predicates})
  end

  defmacro matches(_binding, _pattern) do
    raise ArgumentError, "matches/2 can only be used inside Exograph.DSL.from/2"
  end

  defmacro contains(_binding, _pattern) do
    raise ArgumentError, "contains/2 can only be used inside Exograph.DSL.from/2"
  end

  defmacro prefix_search(_field, _value) do
    raise ArgumentError, "prefix_search/2 can only be used inside Exograph.DSL.from/2"
  end

  defp binding_name!({name, _meta, context}) when is_atom(name) and is_atom(context), do: name

  defp binding_name!(ast) do
    raise ArgumentError, "expected a binding such as `f`, got: #{Macro.to_string(ast)}"
  end

  defp source!(source_ast, caller) do
    case Macro.expand(source_ast, caller) do
      Exograph.Fragment -> :fragment
      Fragment -> :fragment
      Exograph.Definition -> :definition
      Definition -> :definition
      Exograph.Reference -> :reference
      Reference -> :reference
      other -> raise ArgumentError, "unsupported Exograph source: #{inspect(other)}"
    end
  end

  defp predicates!(clauses, binding) do
    clauses
    |> Keyword.get_values(:where)
    |> Enum.map(&predicate!(&1, binding))
  end

  defp predicate!({:matches, _meta, [binding_ast, pattern]}, binding) when is_binary(pattern) do
    assert_binding!(binding_ast, binding)
    {:matches, binding, pattern}
  end

  defp predicate!({:contains, _meta, [binding_ast, pattern]}, binding) when is_binary(pattern) do
    assert_binding!(binding_ast, binding)
    {:contains, binding, pattern}
  end

  defp predicate!({:prefix_search, _meta, [field_ast, value]}, binding) when is_binary(value) do
    {:field, ^binding, field} = field!(field_ast, binding)
    {:prefix_search, binding, field, value}
  end

  defp predicate!({:==, _meta, [field_ast, value]}, binding) do
    {:field, ^binding, field} = field!(field_ast, binding)
    {:eq, binding, field, value}
  end

  defp predicate!(ast, _binding) do
    raise ArgumentError, "unsupported Exograph predicate: #{Macro.to_string(ast)}"
  end

  defp assert_binding!({name, _meta, context}, name) when is_atom(context), do: :ok

  defp assert_binding!(ast, binding) do
    raise ArgumentError,
          "predicate must target binding `#{binding}`, got: #{Macro.to_string(ast)}"
  end

  defp field!({{:., _meta, [binding_ast, field]}, _call_meta, []}, binding) when is_atom(field) do
    assert_binding!(binding_ast, binding)
    {:field, binding, field}
  end

  defp field!(ast, _binding) do
    raise ArgumentError, "expected a field access such as `d.name`, got: #{Macro.to_string(ast)}"
  end
end
