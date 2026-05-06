defmodule Exograph.TreeStore.Postgres do
  @moduledoc """
  Durable AST tree node store backed by Ecto and Postgres.
  """

  @behaviour Exograph.TreeStore

  import Ecto.Query

  alias Ecto.Multi
  alias Exograph.Postgres
  alias Exograph.Postgres.TreeNodeRecord
  alias Exograph.Tree

  defstruct repo: nil, prefix: "exograph"

  @type t :: %__MODULE__{repo: module(), prefix: String.t()}

  @impl true
  def new(opts \\ []) do
    if Keyword.get(opts, :migrate?, false), do: Postgres.migrate!(opts)

    {:ok,
     %__MODULE__{repo: Postgres.fetch_repo!(opts), prefix: Keyword.get(opts, :prefix, "exograph")}}
  end

  @impl true
  def put_fragments(%__MODULE__{} = store, fragments) do
    fragment_ids = Enum.map(fragments, & &1.id)
    records = fragments |> Tree.nodes() |> Enum.map(&TreeNodeRecord.from_node/1)

    multi =
      Multi.new()
      |> Multi.delete_all(
        :delete_existing,
        from(node in {source(store), TreeNodeRecord}, where: node.fragment_id in ^fragment_ids)
      )
      |> Multi.insert_all(:insert_nodes, {source(store), TreeNodeRecord}, records)

    case store.repo.transaction(multi) do
      {:ok, _changes} -> {:ok, store}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  @impl true
  def nodes(%__MODULE__{} = store, fragment_id) do
    query =
      from(node in {source(store), TreeNodeRecord},
        where: node.fragment_id == ^fragment_id,
        order_by: [asc: node.preorder]
      )

    store.repo.all(query)
    |> Enum.map(&TreeNodeRecord.to_node/1)
  end

  defp source(store), do: "#{store.prefix}_tree_nodes"
end
