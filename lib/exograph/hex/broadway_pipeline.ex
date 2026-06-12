defmodule Exograph.Hex.BroadwayPipeline do
  @moduledoc false

  use Broadway

  alias Broadway.Message
  alias Exograph.Hex.Progress

  @behaviour Broadway.Acknowledger

  def index(entries, opts) do
    name = Keyword.get(opts, :name, unique_name())
    owner = self()
    total = length(entries)
    started = System.monotonic_time(:millisecond)

    {:ok, pid} =
      Broadway.start_link(__MODULE__,
        name: name,
        context: %{opts: opts},
        producer: [
          module: {Exograph.Hex.BroadwayProducer, entries: Enum.with_index(entries)},
          transformer: {__MODULE__, :transform, [%{owner: owner}]},
          concurrency: 1
        ],
        processors: [
          default: [
            concurrency: Keyword.get(opts, :concurrency, 4),
            max_demand: Keyword.get(opts, :max_demand, 1)
          ]
        ]
      )

    results = await_results(total, %{ok: 0, skipped: 0, error: 0})
    Broadway.stop(name)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end

    elapsed = System.monotonic_time(:millisecond) - started
    {results, elapsed}
  end

  def transform({entry, index}, [%{owner: owner}]) do
    %Message{data: %{entry: entry, index: index}, acknowledger: {__MODULE__, owner, nil}}
  end

  @impl Broadway
  def handle_message(_, message, %{opts: opts}) do
    %{entry: entry, index: index} = message.data
    Progress.package_started(entry)

    result = Exograph.Hex.Corpus.index_entry(entry, index, opts)
    Progress.package_done(entry, result)

    Message.update_data(message, &Map.put(&1, :result, result))
  rescue
    error ->
      result = {:error, Exception.message(error)}
      Progress.package_done(message.data.entry, result)
      Message.update_data(message, &Map.put(&1, :result, result))
  end

  @impl Broadway.Acknowledger
  def ack(owner, successful, failed) do
    send(owner, {:hex_broadway_ack, Enum.map(successful, & &1.data), Enum.map(failed, & &1.data)})
    :ok
  end

  defp await_results(0, acc), do: acc

  defp await_results(remaining, acc) do
    receive do
      {:hex_broadway_ack, successful, failed} ->
        messages = successful ++ failed

        next =
          Enum.reduce(messages, acc, fn
            %{result: :ok}, acc -> %{acc | ok: acc.ok + 1}
            %{result: :skipped}, acc -> %{acc | skipped: acc.skipped + 1}
            %{result: {:error, _}}, acc -> %{acc | error: acc.error + 1}
            _message, acc -> %{acc | error: acc.error + 1}
          end)

        await_results(remaining - length(messages), next)
    end
  end

  defp unique_name do
    :erlang.unique_integer([:positive])
    |> then(&Module.concat(__MODULE__, "Pipeline#{&1}"))
  end
end
