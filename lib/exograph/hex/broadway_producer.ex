defmodule Exograph.Hex.BroadwayProducer do
  @moduledoc false

  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    entries = Keyword.fetch!(opts, :entries)
    {:producer, %{entries: :queue.from_list(entries)}}
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    {events, entries} = take_entries(state.entries, demand, [])
    {:noreply, events, %{state | entries: entries}}
  end

  defp take_entries(entries, 0, acc), do: {Enum.reverse(acc), entries}

  defp take_entries(entries, demand, acc) do
    case :queue.out(entries) do
      {{:value, entry}, rest} -> take_entries(rest, demand - 1, [entry | acc])
      {:empty, rest} -> {Enum.reverse(acc), rest}
    end
  end
end
