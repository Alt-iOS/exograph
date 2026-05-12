defmodule Exograph.DSL.JoinSemantics do
  @moduledoc false

  import Ecto.Query

  alias Exograph.DSL.Plan

  @function_fragment_kinds [:def, :defp, :defmacro, :defmacrop]

  def function_fragment_kinds, do: @function_fragment_kinds

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

  def where_call_definition_pairs(query, %Plan{
        joins: [%{assoc: :definitions}, %{assoc: :calls}, _]
      }) do
    where(
      query,
      [_fragment, definition, edge, _],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(query, %Plan{
        joins: [%{assoc: :definitions}, _, %{assoc: :calls}]
      }) do
    where(
      query,
      [_fragment, definition, _, edge],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(query, %Plan{
        joins: [%{assoc: :calls}, %{assoc: :definitions}, _]
      }) do
    where(
      query,
      [_fragment, edge, definition, _],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(query, %Plan{
        joins: [%{assoc: :calls}, _, %{assoc: :definitions}]
      }) do
    where(
      query,
      [_fragment, edge, _, definition],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(query, %Plan{
        joins: [_, %{assoc: :definitions}, %{assoc: :calls}]
      }) do
    where(
      query,
      [_fragment, _, definition, edge],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(query, %Plan{
        joins: [_, %{assoc: :calls}, %{assoc: :definitions}]
      }) do
    where(
      query,
      [_fragment, _, edge, definition],
      edge.caller_qualified_name == definition.qualified_name
    )
  end

  def where_call_definition_pairs(query, %Plan{}), do: query
end
