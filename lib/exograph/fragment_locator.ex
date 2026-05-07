defmodule Exograph.FragmentLocator do
  @moduledoc false

  def containing_fragment_id(nil, _line), do: nil
  def containing_fragment_id(_fragments, nil), do: nil

  def containing_fragment_id(fragments, line) do
    case containing_fragment(fragments, line) do
      nil -> nil
      fragment -> fragment.id
    end
  end

  defp containing_fragment(fragments, line) do
    fragments
    |> Enum.filter(&contains_line?(&1, line))
    |> Enum.min_by(& &1.mass, fn -> nil end)
  end

  defp contains_line?(fragment, line) do
    fragment.line <= line and (is_nil(fragment.end_line) or line <= fragment.end_line)
  end
end
