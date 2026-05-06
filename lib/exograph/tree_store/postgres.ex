defmodule Exograph.TreeStore.Postgres do
  @moduledoc """
  Durable AST tree node store backed by Ecto and Postgres.
  """

  @behaviour Exograph.TreeStore

  alias Exograph.Postgres
  alias Exograph.Postgres.{FragmentRecord, Options}
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
  def put_fragments(%__MODULE__{} = store, fragments) when is_list(fragments), do: {:ok, store}

  @impl true
  def nodes(%__MODULE__{} = store, fragment_id) do
    case store.repo.get({Options.fragments_source(store.prefix), FragmentRecord}, fragment_id) do
      %FragmentRecord{} = record ->
        record
        |> FragmentRecord.to_fragment()
        |> Tree.nodes()

      nil ->
        []
    end
  end
end
