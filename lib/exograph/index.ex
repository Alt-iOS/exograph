defmodule Exograph.Index do
  @moduledoc """
  Runtime handle for an Exograph index.

  The handle keeps the Postgres candidate retrieval, fragment storage, and tree
  access modules together for query execution.
  """

  alias Exograph.{FragmentStore, InvertedIndex, TreeStore}

  @type t :: %__MODULE__{
          inverted_backend: module(),
          inverted: InvertedIndex.index(),
          fragment_store_backend: module(),
          fragment_store: FragmentStore.store(),
          tree_store_backend: module() | nil,
          tree_store: TreeStore.store() | nil
        }

  defstruct inverted_backend: Exograph.InvertedIndex.Postgres,
            inverted: nil,
            fragment_store_backend: Exograph.FragmentStore.Postgres,
            fragment_store: nil,
            tree_store_backend: Exograph.TreeStore.Postgres,
            tree_store: nil
end
