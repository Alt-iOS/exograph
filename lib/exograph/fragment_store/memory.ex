defmodule Exograph.FragmentStore.Memory do
  @moduledoc """
  In-memory fragment store.
  """

  @behaviour Exograph.FragmentStore

  defstruct fragments: %{}

  @type t :: %__MODULE__{fragments: map()}

  @impl true
  def new(_opts \\ []), do: {:ok, %__MODULE__{}}

  @impl true
  def put(%__MODULE__{} = store, fragments) when is_list(fragments) do
    fragments = Enum.reduce(fragments, store.fragments, &Map.put(&2, &1.id, &1))
    {:ok, %{store | fragments: fragments}}
  end

  @impl true
  def get(%__MODULE__{fragments: fragments}, id), do: Map.fetch(fragments, id)

  @impl true
  def all(%__MODULE__{fragments: fragments}), do: Map.values(fragments)

  @impl true
  def count(%__MODULE__{fragments: fragments}), do: map_size(fragments)

  @impl true
  def term_frequencies(%__MODULE__{fragments: fragments}, terms) do
    wanted = MapSet.new(terms)

    Enum.reduce(fragments, %{}, fn {_id, fragment}, acc ->
      fragment.terms
      |> MapSet.intersection(wanted)
      |> Enum.reduce(acc, fn term, acc -> Map.update(acc, term, 1, &(&1 + 1)) end)
    end)
  end
end
