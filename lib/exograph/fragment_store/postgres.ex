defmodule Exograph.FragmentStore.Postgres do
  @moduledoc """
  Durable fragment store backed by Ecto and Postgres.
  """

  @behaviour Exograph.FragmentStore

  import Ecto.Query

  alias Exograph.Postgres
  alias Exograph.Postgres.FragmentRecord

  defstruct repo: nil, prefix: "exograph"

  @type t :: %__MODULE__{repo: module(), prefix: String.t()}

  @impl true
  def new(opts \\ []) do
    if Keyword.get(opts, :migrate?, false), do: Postgres.migrate!(opts)

    {:ok,
     %__MODULE__{repo: Postgres.fetch_repo!(opts), prefix: Keyword.get(opts, :prefix, "exograph")}}
  end

  @impl true
  def put(%__MODULE__{} = store, fragments) when is_list(fragments) do
    now = DateTime.utc_now(:microsecond)

    entries =
      Enum.map(fragments, fn fragment ->
        fragment
        |> FragmentRecord.from_fragment()
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    store.repo.insert_all(
      {source(store), FragmentRecord},
      entries,
      conflict_target: [:id],
      on_conflict: {:replace_all_except, [:id, :inserted_at]}
    )

    {:ok, store}
  end

  @impl true
  def get(%__MODULE__{} = store, fragment_id) do
    case store.repo.get({source(store), FragmentRecord}, fragment_id) do
      %FragmentRecord{} = record -> {:ok, FragmentRecord.to_fragment(record)}
      nil -> :error
    end
  end

  @impl true
  def all(%__MODULE__{} = store) do
    query =
      from(fragment in {source(store), FragmentRecord},
        order_by: [asc: fragment.file, asc: fragment.line, asc: fragment.id]
      )

    store.repo.all(query)
    |> Enum.map(&FragmentRecord.to_fragment/1)
  end

  defp source(store), do: "#{store.prefix}_fragments"
end
