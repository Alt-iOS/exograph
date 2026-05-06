defmodule Exograph.Index do
  @moduledoc """
  Runtime handle for an Exograph index.

  The handle deliberately separates candidate retrieval from fragment storage so
  TantivyEx can stay an inverted-index backend while AST/source remain available
  for exact verification.
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

  defstruct inverted_backend: Exograph.InvertedIndex.Memory,
            inverted: nil,
            fragment_store_backend: Exograph.FragmentStore.Memory,
            fragment_store: nil,
            tree_store_backend: Exograph.TreeStore.Memory,
            tree_store: nil
end
