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
  def get(%__MODULE__{fragments: fragments}, id) do
    case Map.fetch(fragments, id) do
      {:ok, fragment} -> {:ok, fragment}
      :error -> :error
    end
  end

  @impl true
  def all(%__MODULE__{fragments: fragments}), do: Map.values(fragments)
end
