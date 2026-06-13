defmodule Exograph.DuckDB.InsertBuffer do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def insert(_buffer, _source, []), do: :ok
  def insert(nil, _source, _entries), do: :ok

  def insert(buffer, source, entries) when is_pid(buffer) do
    GenServer.call(buffer, {:insert, source, entries}, :infinity)
  end

  def flush(nil), do: :ok

  def flush(buffer) when is_pid(buffer) do
    GenServer.call(buffer, :flush, :infinity)
  end

  def stop(nil), do: :ok

  def stop(buffer) when is_pid(buffer) do
    GenServer.stop(buffer, :normal, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       repo: Keyword.fetch!(opts, :repo),
       dynamic_repo: Keyword.get(opts, :dynamic_repo),
       chunk_size: Keyword.get(opts, :chunk_size, 50_000),
       buffers: %{},
       counts: %{}
     }}
  end

  @impl true
  def handle_call({:insert, source, entries}, _from, state) do
    entries = List.wrap(entries)
    batches = Map.get(state.buffers, source, [])
    count = Map.get(state.counts, source, 0) + length(entries)

    state = %{
      state
      | buffers: Map.put(state.buffers, source, [entries | batches]),
        counts: Map.put(state.counts, source, count)
    }

    state = if count >= state.chunk_size, do: flush_source(state, source), else: state
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_all(state)}
  end

  @impl true
  def terminate(_reason, state) do
    flush_all(state)
    :ok
  end

  defp flush_all(state) do
    state.buffers
    |> Map.keys()
    |> Enum.reduce(state, &flush_source(&2, &1))
  end

  defp flush_source(state, source) do
    entries =
      state.buffers
      |> Map.get(source, [])
      |> Enum.reverse()
      |> Enum.flat_map(& &1)

    if entries != [] do
      with_dynamic_repo(state, fn ->
        state.repo.insert_all(source, entries,
          insert_method: :append,
          chunk_every: 10_000,
          timeout: :infinity
        )
      end)
    end

    %{
      state
      | buffers: Map.delete(state.buffers, source),
        counts: Map.delete(state.counts, source)
    }
  end

  defp with_dynamic_repo(%{dynamic_repo: nil}, fun), do: fun.()

  defp with_dynamic_repo(%{repo: repo, dynamic_repo: dynamic_repo}, fun) do
    if function_exported?(repo, :put_dynamic_repo, 1) and
         function_exported?(repo, :get_dynamic_repo, 0) do
      previous = repo.get_dynamic_repo()
      repo.put_dynamic_repo(dynamic_repo)

      try do
        fun.()
      after
        repo.put_dynamic_repo(previous)
      end
    else
      fun.()
    end
  end
end
