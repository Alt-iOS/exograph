defmodule Exograph.DSL.JoinSemantics do
  @moduledoc false

  import Ecto.Query

  alias Exograph.DSL.Plan

  @function_fragment_kinds [:def, :defp, :defmacro, :defmacrop]

  def function_fragment_kinds, do: @function_fragment_kinds

  def containing_assoc(%Plan{joins: joins}, :calls) do
    if Enum.any?(joins, &(&1.assoc == :definitions)), do: :calls_with_definition, else: :calls
  end

  def containing_assoc(%Plan{}, assoc), do: assoc

  def where_containing_fragment_binding(query, :calls_with_definition, _position), do: query

  def where_containing_fragment_binding(query, :definitions, :one) do
    where(query, [fragment, joined, later], joined.line >= fragment.line and is_nil(later.id))
  end

  def where_containing_fragment_binding(query, assoc, :one)
      when assoc in [:references, :calls] do
    where(query, [fragment, joined, later], joined.line >= fragment.line and is_nil(later.id))
  end

  def where_containing_fragment_binding(query, :definitions, :two_first) do
    where(
      query,
      [fragment, first, _second, first_later, _second_later],
      first.line >= fragment.line and is_nil(first_later.id)
    )
  end

  def where_containing_fragment_binding(query, assoc, :two_first)
      when assoc in [:references, :calls] do
    where(
      query,
      [fragment, first, _second, first_later, _second_later],
      first.line >= fragment.line and is_nil(first_later.id)
    )
  end

  def where_containing_fragment_binding(query, :definitions, :two_second) do
    where(
      query,
      [fragment, _first, second, _first_later, second_later],
      second.line >= fragment.line and is_nil(second_later.id)
    )
  end

  def where_containing_fragment_binding(query, assoc, :two_second)
      when assoc in [:references, :calls] do
    where(
      query,
      [fragment, _first, second, _first_later, second_later],
      second.line >= fragment.line and is_nil(second_later.id)
    )
  end

  def where_containing_fragment_binding(query, :definitions, :three_first) do
    where(
      query,
      [fragment, first, _second, _third, first_later, _second_later, _third_later],
      first.line >= fragment.line and is_nil(first_later.id)
    )
  end

  def where_containing_fragment_binding(query, assoc, :three_first)
      when assoc in [:references, :calls] do
    where(
      query,
      [fragment, first, _second, _third, first_later, _second_later, _third_later],
      first.line >= fragment.line and is_nil(first_later.id)
    )
  end

  def where_containing_fragment_binding(query, :definitions, :three_second) do
    where(
      query,
      [fragment, _first, second, _third, _first_later, second_later, _third_later],
      second.line >= fragment.line and is_nil(second_later.id)
    )
  end

  def where_containing_fragment_binding(query, assoc, :three_second)
      when assoc in [:references, :calls] do
    where(
      query,
      [fragment, _first, second, _third, _first_later, second_later, _third_later],
      second.line >= fragment.line and is_nil(second_later.id)
    )
  end

  def where_containing_fragment_binding(query, :definitions, :three_third) do
    where(
      query,
      [fragment, _first, _second, third, _first_later, _second_later, third_later],
      third.line >= fragment.line and is_nil(third_later.id)
    )
  end

  def where_containing_fragment_binding(query, assoc, :three_third)
      when assoc in [:references, :calls] do
    where(
      query,
      [fragment, _first, _second, third, _first_later, _second_later, third_later],
      third.line >= fragment.line and is_nil(third_later.id)
    )
  end

  def where_call_definition_pairs(query, %Plan{joins: [%{assoc: :definitions}, %{assoc: :calls}]}) do
    where(
      query,
      [_fragment, definition, edge],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(query, %Plan{joins: [%{assoc: :calls}, %{assoc: :definitions}]}) do
    where(
      query,
      [_fragment, edge, definition],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(
        query,
        %Plan{joins: [%{assoc: :definitions}, %{assoc: :calls}, _third]}
      ) do
    where(
      query,
      [_fragment, definition, edge, _third],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(
        query,
        %Plan{joins: [%{assoc: :definitions}, _second, %{assoc: :calls}]}
      ) do
    where(
      query,
      [_fragment, definition, _second, edge],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(
        query,
        %Plan{joins: [%{assoc: :calls}, %{assoc: :definitions}, _third]}
      ) do
    where(
      query,
      [_fragment, edge, definition, _third],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(
        query,
        %Plan{joins: [%{assoc: :calls}, _second, %{assoc: :definitions}]}
      ) do
    where(
      query,
      [_fragment, edge, _second, definition],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(
        query,
        %Plan{joins: [_first, %{assoc: :definitions}, %{assoc: :calls}]}
      ) do
    where(
      query,
      [_fragment, _first, definition, edge],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(
        query,
        %Plan{joins: [_first, %{assoc: :calls}, %{assoc: :definitions}]}
      ) do
    where(
      query,
      [_fragment, _first, edge, definition],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(query, %Plan{}), do: query
end
