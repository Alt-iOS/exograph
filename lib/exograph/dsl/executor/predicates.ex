defmodule Exograph.DSL.Executor.Predicates do
  @moduledoc false

  import Ecto.Query

  alias Exograph.DSL.Sources

  @doc false
  def where_source_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_first_binding_predicate(query, predicate, source)
    end)
  end

  @doc false
  def where_first_binding_join_predicates(query, predicates, source) do
    Enum.reduce(predicates, query, fn predicate, query ->
      where_first_binding_predicate(query, predicate, source)
    end)
  end

  @doc false
  def where_first_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [row], ilike(field(row, ^field), ^"#{value}%"))
  end

  def where_first_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [row], field(row, ^field) == ^value)
  end

  def where_first_binding_predicate(query, {:cmp, _binding, field, op, value}, source) do
    Sources.assert_field!(source, field)
    where_first_cmp(query, field, op, value)
  end

  def where_first_binding_predicate(query, {:in, _binding, field, values}, source) do
    Sources.assert_field!(source, field)
    where(query, [row], field(row, ^field) in ^values)
  end

  @doc false
  def where_second_binding_call_edge_predicates(query, predicates, call_edge_binding) do
    where_second_binding_predicates(query, predicates, call_edge_binding, :calls)
  end

  @doc false
  def where_second_binding_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_second_binding_predicate(query, predicate, source)
    end)
  end

  @doc false
  def where_second_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, row], ilike(field(row, ^field), ^"#{value}%"))
  end

  def where_second_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, row], field(row, ^field) == ^value)
  end

  def where_second_binding_predicate(query, {:cmp, _binding, field, op, value}, source) do
    Sources.assert_field!(source, field)
    where_second_cmp(query, field, op, value)
  end

  def where_second_binding_predicate(query, {:in, _binding, field, values}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, row], field(row, ^field) in ^values)
  end

  @doc false
  def where_third_binding_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_third_binding_predicate(query, predicate, source)
    end)
  end

  @doc false
  def where_third_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, row], ilike(field(row, ^field), ^"#{value}%"))
  end

  def where_third_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, row], field(row, ^field) == ^value)
  end

  def where_third_binding_predicate(query, {:cmp, _binding, field, op, value}, source) do
    Sources.assert_field!(source, field)
    where_third_cmp(query, field, op, value)
  end

  def where_third_binding_predicate(query, {:in, _binding, field, values}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, row], field(row, ^field) in ^values)
  end

  @doc false
  def where_fourth_binding_predicates(query, predicates, binding, source) do
    predicates
    |> predicates_for(binding)
    |> Enum.reduce(query, fn predicate, query ->
      where_fourth_binding_predicate(query, predicate, source)
    end)
  end

  @doc false
  def where_fourth_binding_predicate(query, {:prefix_search, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, _third, row], ilike(field(row, ^field), ^"#{value}%"))
  end

  def where_fourth_binding_predicate(query, {:eq, _binding, field, value}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, _third, row], field(row, ^field) == ^value)
  end

  def where_fourth_binding_predicate(query, {:cmp, _binding, field, op, value}, source) do
    Sources.assert_field!(source, field)
    where_fourth_cmp(query, field, op, value)
  end

  def where_fourth_binding_predicate(query, {:in, _binding, field, values}, source) do
    Sources.assert_field!(source, field)
    where(query, [_first, _second, _third, row], field(row, ^field) in ^values)
  end

  @doc false
  def where_call_edge_predicates(query, predicates) do
    Enum.reduce(predicates, query, fn predicate, query ->
      where_first_binding_predicate(query, predicate, :call_edge)
    end)
  end

  @doc false
  def where_first_cmp(query, field, :>, value),
    do: where(query, [row], field(row, ^field) > ^value)

  def where_first_cmp(query, field, :<, value),
    do: where(query, [row], field(row, ^field) < ^value)

  def where_first_cmp(query, field, :>=, value),
    do: where(query, [row], field(row, ^field) >= ^value)

  def where_first_cmp(query, field, :<=, value),
    do: where(query, [row], field(row, ^field) <= ^value)

  @doc false
  def where_second_cmp(query, field, :>, value),
    do: where(query, [_first, row], field(row, ^field) > ^value)

  def where_second_cmp(query, field, :<, value),
    do: where(query, [_first, row], field(row, ^field) < ^value)

  def where_second_cmp(query, field, :>=, value),
    do: where(query, [_first, row], field(row, ^field) >= ^value)

  def where_second_cmp(query, field, :<=, value),
    do: where(query, [_first, row], field(row, ^field) <= ^value)

  @doc false
  def where_third_cmp(query, field, :>, value),
    do: where(query, [_first, _second, row], field(row, ^field) > ^value)

  def where_third_cmp(query, field, :<, value),
    do: where(query, [_first, _second, row], field(row, ^field) < ^value)

  def where_third_cmp(query, field, :>=, value),
    do: where(query, [_first, _second, row], field(row, ^field) >= ^value)

  def where_third_cmp(query, field, :<=, value),
    do: where(query, [_first, _second, row], field(row, ^field) <= ^value)

  @doc false
  def where_fourth_cmp(query, field, :>, value),
    do: where(query, [_first, _second, _third, row], field(row, ^field) > ^value)

  def where_fourth_cmp(query, field, :<, value),
    do: where(query, [_first, _second, _third, row], field(row, ^field) < ^value)

  def where_fourth_cmp(query, field, :>=, value),
    do: where(query, [_first, _second, _third, row], field(row, ^field) >= ^value)

  def where_fourth_cmp(query, field, :<=, value),
    do: where(query, [_first, _second, _third, row], field(row, ^field) <= ^value)

  @doc false
  def predicates_for(predicates, nil), do: Enum.filter(predicates, &field_predicate?/1)

  def predicates_for(predicates, binding) do
    Enum.filter(predicates, fn
      {_kind, ^binding, _field, _value} -> true
      {:cmp, ^binding, _field, _op, _value} -> true
      _predicate -> false
    end)
  end

  @doc false
  def field_predicate?({_kind, _binding, _field, _value}), do: true
  def field_predicate?({:cmp, _binding, _field, _op, _value}), do: true
  def field_predicate?(_predicate), do: false
end
