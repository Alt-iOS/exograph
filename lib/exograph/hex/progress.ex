defmodule Exograph.Hex.Progress do
  @moduledoc false

  use GenServer

  @topic "hex:indexing"

  defstruct total: 0,
            processed: 0,
            ok: 0,
            skipped: 0,
            errors: 0,
            current: nil,
            started_at: nil,
            finished_at: nil,
            recent: [],
            state: :idle

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_run(total) do
    if alive?(), do: GenServer.call(__MODULE__, {:start_run, total})
  end

  def package_done(entry, status) do
    if alive?(), do: GenServer.call(__MODULE__, {:package_done, entry, status})
  end

  def package_started(entry) do
    if alive?(), do: GenServer.cast(__MODULE__, {:package_started, entry})
  end

  def finish_run do
    if alive?(), do: GenServer.call(__MODULE__, :finish_run)
  end

  def get do
    if alive?(), do: GenServer.call(__MODULE__, :get), else: %__MODULE__{}
  end

  def subscribe do
    if pubsub_available?() do
      Phoenix.PubSub.subscribe(Exograph.Web.PubSub, @topic)
    end
  end

  defp alive?, do: GenServer.whereis(__MODULE__) != nil

  defp pubsub_available? do
    Code.ensure_loaded?(Phoenix.PubSub) and GenServer.whereis(Exograph.Web.PubSub) != nil
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:start_run, total}, _from, _state) do
    new_state = %__MODULE__{
      total: total,
      started_at: System.monotonic_time(:millisecond),
      state: :running
    }

    broadcast(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:package_done, entry, status}, _from, state) do
    new_state =
      state
      |> Map.update!(:processed, &(&1 + 1))
      |> increment_status(status)
      |> prepend_recent(entry, status)

    broadcast(new_state)
    {:reply, new_state, new_state}
  end

  def handle_call(:finish_run, _from, state) do
    new_state = %{state | state: :done, finished_at: System.monotonic_time(:millisecond)}
    broadcast(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:package_started, entry}, state) do
    new_state = %{state | current: entry}
    broadcast(new_state)
    {:noreply, new_state}
  end

  defp increment_status(state, :ok), do: Map.update!(state, :ok, &(&1 + 1))
  defp increment_status(state, :skipped), do: Map.update!(state, :skipped, &(&1 + 1))
  defp increment_status(state, {:error, _}), do: Map.update!(state, :errors, &(&1 + 1))

  defp prepend_recent(state, entry, status) do
    item = %{name: entry.name, version: entry.version, status: status, at: DateTime.utc_now()}
    %{state | recent: Enum.take([item | state.recent], 50)}
  end

  defp broadcast(state) do
    if pubsub_available?() do
      Phoenix.PubSub.broadcast(Exograph.Web.PubSub, @topic, {:progress, state})
    end
  end
end
