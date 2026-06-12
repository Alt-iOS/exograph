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
        context: %{opts: opts, shards: nil},
        producer: producer(Enum.with_index(entries), owner),
        processors: processors(opts),
        batchers: [default: batcher(opts)]
      )

    finish(name, pid, total, started)
  end

  def index_sharded(shards, opts) do
    name = Keyword.get(opts, :name, unique_name())
    owner = self()

    jobs =
      Enum.flat_map(shards, fn shard ->
        Enum.with_index(shard.entries, fn entry, index ->
          %{entry: entry, index: index, shard_id: shard.id}
        end)
      end)

    shard_by_id = Map.new(shards, &{&1.id, &1})
    batchers = Enum.map(shards, &{batcher_name(&1.id), batcher(opts)})
    started = System.monotonic_time(:millisecond)

    {:ok, pid} =
      Broadway.start_link(__MODULE__,
        name: name,
        context: %{opts: opts, shards: shard_by_id},
        producer: producer(jobs, owner),
        processors: processors(opts),
        batchers: batchers
      )

    finish(name, pid, length(jobs), started)
  end

  def transform(data, [%{owner: owner}]) do
    %Message{data: normalize_job(data), acknowledger: {__MODULE__, owner, nil}}
  end

  @impl Broadway
  def handle_message(_, message, %{shards: nil}) do
    message
  end

  def handle_message(_, message, %{shards: shards}) when is_map(shards) do
    Message.put_batcher(message, batcher_name(message.data.shard_id))
  end

  @impl Broadway
  def handle_batch(_batcher, messages, _batch_info, %{opts: opts, shards: nil}) do
    Enum.map(messages, &index_message(&1, opts))
  end

  def handle_batch(_batcher, messages, _batch_info, %{opts: opts, shards: shards}) do
    shard_id = messages |> hd() |> then(& &1.data.shard_id)
    shard = Map.fetch!(shards, shard_id)

    Exograph.DuckDBShards.with_repo(shard, fn ->
      shard_opts =
        opts
        |> Keyword.put(:repo, shard.repo)
        |> Keyword.put(:dynamic_repo, shard.dynamic_repo)
        |> Keyword.put(:prefix, shard.prefix)

      Enum.map(messages, &index_message(&1, shard_opts))
    end)
  end

  @impl Broadway
  def handle_failed(messages, _context), do: messages

  @impl Broadway.Acknowledger
  def ack(owner, successful, failed) do
    send(owner, {:hex_broadway_ack, Enum.map(successful, & &1.data), Enum.map(failed, & &1.data)})
    :ok
  end

  defp producer(entries, owner) do
    [
      module: {Exograph.Hex.BroadwayProducer, entries: entries},
      transformer: {__MODULE__, :transform, [%{owner: owner}]},
      concurrency: 1
    ]
  end

  defp processors(opts) do
    [
      default: [
        concurrency: Keyword.get(opts, :processor_concurrency, 1),
        max_demand: Keyword.get(opts, :processor_max_demand, 1)
      ]
    ]
  end

  defp batcher(opts) do
    [
      concurrency: 1,
      batch_size: Keyword.get(opts, :batch_size, 1),
      batch_timeout: Keyword.get(opts, :batch_timeout, 100)
    ]
  end

  defp index_message(message, opts) do
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

  defp finish(name, pid, total, started) do
    results = await_results(total, %{ok: 0, skipped: 0, error: 0})
    Broadway.stop(name)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end

    {results, System.monotonic_time(:millisecond) - started}
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

  defp normalize_job({entry, index}), do: %{entry: entry, index: index}
  defp normalize_job(%{entry: _entry, index: _index} = job), do: job

  defp batcher_name(shard_id), do: String.to_atom("shard_#{shard_id}")

  defp unique_name do
    :erlang.unique_integer([:positive])
    |> then(&Module.concat(__MODULE__, "Pipeline#{&1}"))
  end
end
