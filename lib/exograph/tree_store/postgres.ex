defmodule Exograph.TreeStore.Postgres do
  @moduledoc """
  Durable AST tree node store backed by Ecto and Postgres.
  """

  @behaviour Exograph.TreeStore

  import Ecto.Query

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
    fragments = fragments |> Enum.uniq_by(& &1.id) |> Enum.filter(&tree_indexed?/1)
    fragment_ids = Enum.map(fragments, & &1.id)
    records = fragments |> Tree.nodes() |> Enum.map(&TreeNodeRecord.from_node/1)

    case store.repo.transaction(
           fn ->
             store.repo.delete_all(
               from(node in {source(store), TreeNodeRecord},
                 where: node.fragment_id in ^fragment_ids
               ),
               timeout: :infinity
             )

             records
             |> Enum.chunk_every(4_000)
             |> Enum.each(fn chunk ->
               store.repo.insert_all({source(store), TreeNodeRecord}, chunk, timeout: :infinity)
             end)
           end,
           timeout: :infinity
         ) do
      {:ok, _result} -> {:ok, store}
      {:error, reason} -> {:error, reason}
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

  defp tree_indexed?(fragment),
    do: fragment.kind in [:module, :def, :defp, :defmacro, :defmacrop]

  defp source(store), do: "#{store.prefix}_tree_nodes"
end
