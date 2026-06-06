defmodule Exograph.Web.SafeEval do
  @moduledoc false

  alias Exograph.DSL.Query

  @source_names %{
    Fragment => :fragment,
    Definition => :definition,
    Reference => :reference,
    CallEdge => :call_edge,
    Exograph.Fragment => :fragment,
    Exograph.Definition => :definition,
    Exograph.Reference => :reference,
    Exograph.CallEdge => :call_edge
  }

  def eval(query_string) do
    case Code.string_to_quoted(query_string, file: "query", columns: true) do
      {:ok, ast} -> interpret(ast)
      {:error, {location, msg_info, token}} -> parse_error(location, msg_info, token)
    end
  end

  defp interpret({:from, _meta, [{:in, _, [binding_ast, source_ast]}, clauses]})
       when is_list(clauses) do
    with {:ok, binding} <- extract_binding(binding_ast),
         {:ok, source} <- extract_source(source_ast),
         {:ok, joins} <- extract_joins(clauses, binding),
         {:ok, predicates} <- extract_predicates(clauses, binding, joins),
         {:ok, select} <- extract_select(clauses),
         {:ok, limit} <- extract_limit(clauses) do
      {:ok,
       %Query{
         source: source,
         binding: binding,
         predicates: predicates,
         joins: joins,
         select: select,
         limit: limit
       }}
    end
  end

  defp interpret(ast) when is_binary(ast), do: {:ok, ast}

  defp interpret(_ast) do
    {:error, %{message: "Expected from(binding in Source, ...) or a pattern string", markers: []}}
  end

  defp extract_binding({name, _meta, nil}) when is_atom(name), do: {:ok, name}
  defp extract_binding(_), do: {:error, error("Invalid binding")}

  defp extract_source({:__aliases__, _, parts}) do
    mod = Module.concat(parts)

    case Map.fetch(@source_names, mod) do
      {:ok, source} ->
        {:ok, source}

      :error ->
        {:error,
         error("Unknown source #{inspect(mod)}. Use Fragment, Definition, Reference, or CallEdge")}
    end
  end

  defp extract_source(atom) when is_atom(atom) do
    case Map.fetch(@source_names, atom) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, error("Unknown source #{inspect(atom)}")}
    end
  end

  defp extract_source(_), do: {:error, error("Invalid source")}

  defp extract_joins(clauses, parent_binding) do
    clauses
    |> Keyword.get_values(:join)
    |> Enum.reduce_while({:ok, []}, fn join_ast, {:ok, acc} ->
      case extract_join(join_ast, parent_binding) do
        {:ok, join} -> {:cont, {:ok, [join | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_ok()
  end

  defp extract_join(
         {:in, _, [binding_ast, {:assoc, _, [parent_ast, assoc_name]}]},
         _parent_binding
       ) do
    with {:ok, binding} <- extract_binding(binding_ast),
         {:ok, parent} <- extract_binding(parent_ast),
         true <- is_atom(assoc_name) do
      {:ok, {:assoc, parent, binding, assoc_name}}
    else
      _ -> {:error, error("Invalid join syntax. Use: join: b in assoc(f, :name)")}
    end
  end

  defp extract_join(_, _), do: {:error, error("Invalid join. Use: join: b in assoc(f, :name)")}

  defp extract_predicates(clauses, binding, joins) do
    join_bindings =
      Enum.map(joins, fn {:assoc, _parent, jb, _assoc} -> jb end)

    all_bindings = MapSet.new([binding | join_bindings])

    clauses
    |> Keyword.get_values(:where)
    |> Enum.reduce_while({:ok, []}, fn where_ast, {:ok, acc} ->
      case extract_predicate(where_ast, all_bindings) do
        {:ok, pred} -> {:cont, {:ok, [pred | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_ok()
  end

  defp extract_predicate({:matches, _, [binding_ast, pattern]}, _bindings)
       when is_binary(pattern) do
    with {:ok, binding} <- extract_binding(binding_ast) do
      {:ok, {:matches, binding, pattern}}
    end
  end

  defp extract_predicate({:contains, _, [binding_ast, pattern]}, _bindings)
       when is_binary(pattern) do
    with {:ok, binding} <- extract_binding(binding_ast) do
      {:ok, {:contains, binding, pattern}}
    end
  end

  defp extract_predicate(
         {:prefix_search, _, [{{:., _, [binding_ast, field]}, _, _}, value]},
         _bindings
       )
       when is_atom(field) and is_binary(value) do
    with {:ok, binding} <- extract_binding(binding_ast) do
      {:ok, {:prefix_search, binding, field, value}}
    end
  end

  defp extract_predicate(
         {:prefix_search, _, [binding_ast, value]},
         _bindings
       )
       when is_binary(value) do
    with {:ok, binding} <- extract_binding(binding_ast) do
      {:ok, {:prefix_search, binding, :name, value}}
    end
  end

  defp extract_predicate({:==, _, [left, right]}, bindings) do
    with {:ok, {binding, field}} <- extract_field_access(left, bindings),
         {:ok, value} <- extract_value(right) do
      {:ok, {:eq, binding, field, value}}
    end
  end

  defp extract_predicate({op, _, [left, right]}, bindings) when op in [:>, :<, :>=, :<=] do
    with {:ok, {binding, field}} <- extract_field_access(left, bindings),
         {:ok, value} <- extract_value(right) do
      {:ok, {:cmp, binding, field, op, value}}
    end
  end

  defp extract_predicate({:in, _, [left, right]}, bindings) when is_list(right) do
    with {:ok, {binding, field}} <- extract_field_access(left, bindings),
         {:ok, values} <- extract_values(right) do
      {:ok, {:in, binding, field, values}}
    end
  end

  defp extract_predicate(ast, _bindings) do
    {:error, error("Unsupported predicate: #{Macro.to_string(ast)}")}
  end

  defp extract_field_access({{:., _, [binding_ast, field]}, _, _}, bindings)
       when is_atom(field) do
    with {:ok, binding} <- extract_binding(binding_ast) do
      if MapSet.member?(bindings, binding) do
        {:ok, {binding, field}}
      else
        {:error, error("Unknown binding #{inspect(binding)}")}
      end
    end
  end

  defp extract_field_access(ast, _bindings) do
    {:error, error("Expected field access like binding.field, got: #{Macro.to_string(ast)}")}
  end

  defp extract_value(value) when is_binary(value), do: {:ok, value}
  defp extract_value(value) when is_integer(value), do: {:ok, value}
  defp extract_value(value) when is_float(value), do: {:ok, value}
  defp extract_value(value) when is_atom(value), do: {:ok, value}
  defp extract_value(value) when is_list(value), do: extract_values(value)

  defp extract_value(ast) do
    if Code.ensure_loaded?(Dune) do
      case Dune.eval_string(Macro.to_string(ast), timeout: 1000, max_heap_size: 1_000_000) do
        %{value: value} -> {:ok, value}
        %{message: msg} -> {:error, error(msg)}
      end
    else
      {:error, error("Unsupported value: #{Macro.to_string(ast)}")}
    end
  end

  defp extract_values(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case extract_value(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_ok()
  end

  defp extract_select(clauses) do
    case Keyword.get(clauses, :select) do
      nil -> {:ok, nil}
      {binding, _meta, nil} when is_atom(binding) -> {:ok, binding}
      {:{}, _, bindings} -> {:ok, {:tuple, Enum.map(bindings, &elem(&1, 0))}}
      {b1, b2} -> {:ok, {:tuple, [elem(b1, 0), elem(b2, 0)]}}
      _ -> {:error, error("Invalid select")}
    end
  end

  defp extract_limit(clauses) do
    case Keyword.get(clauses, :limit) do
      nil -> {:ok, nil}
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, error("Limit must be a positive integer")}
    end
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, _} = error), do: error

  defp error(message), do: %{message: message, markers: []}

  defp parse_error(location, msg_info, token) do
    line = if is_list(location), do: Keyword.get(location, :line, 1), else: location
    col = if is_list(location), do: Keyword.get(location, :column, 1), else: 1
    message = format_parse_error(msg_info, token)
    {:error, %{message: message, markers: [%{line: line, column: col, message: message}]}}
  end

  defp format_parse_error({msg, extra}, token) when is_binary(msg) and is_binary(extra),
    do: "#{msg}#{extra}#{token}"

  defp format_parse_error(msg, token) when is_binary(msg), do: "#{msg}#{token}"
end
