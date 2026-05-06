defmodule Exograph.Backend.Postgres do
  @moduledoc """
  Ecto/Postgres backend profile.

  This is the primary durable backend. It stores fragments and AST tree nodes via
  Ecto schemas and can create a ParadeDB BM25 index when `migrate?: true` and
  `bm25?: true` are used.
  """

  @behaviour Exograph.Backend

  alias Exograph.Backend
  alias Exograph.FragmentStore.Postgres, as: PostgresFragmentStore
  alias Exograph.InvertedIndex.Postgres, as: PostgresInvertedIndex
  alias Exograph.TreeStore.Postgres, as: PostgresTreeStore

  @impl true
  def config(opts) do
    shared = Backend.shared_store_opts(opts)

    [
      inverted: PostgresInvertedIndex,
      inverted_opts: shared,
      fragment_store: PostgresFragmentStore,
      fragment_store_opts: Keyword.put(shared, :migrate?, false),
      tree_store: PostgresTreeStore,
      tree_store_opts: Keyword.put(shared, :migrate?, false)
    ]
  end
end
