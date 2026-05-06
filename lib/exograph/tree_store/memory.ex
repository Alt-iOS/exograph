defmodule Exograph.TreeStore.Memory do
  @moduledoc """
  In-memory tree node store.
  """

  @behaviour Exograph.TreeStore

  alias Exograph.Tree

  defstruct nodes_by_fragment: %{}

  @type t :: %__MODULE__{nodes_by_fragment: map()}

  @impl true
  def new(_opts \\ []), do: {:ok, %__MODULE__{}}

  @impl true
  def put_fragments(%__MODULE__{} = store, fragments) do
    nodes_by_fragment =
      Enum.reduce(fragments, store.nodes_by_fragment, fn fragment, acc ->
        Map.put(acc, fragment.id, Tree.nodes(fragment))
      end)

    {:ok, %{store | nodes_by_fragment: nodes_by_fragment}}
  end

  @impl true
  def nodes(%__MODULE__{nodes_by_fragment: nodes_by_fragment}, fragment_id) do
    Map.get(nodes_by_fragment, fragment_id, [])
  end
end
