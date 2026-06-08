defmodule Exograph.Storage.Ecto.SQL do
  @moduledoc false

  def bulk_insert_all(repo, source, entries, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 1_000)
    max_concurrency = Keyword.get_lazy(opts, :max_concurrency, fn -> repo_pool_size(repo) end)
    insert_opts = Keyword.drop(opts, [:chunk_size, :max_concurrency])

    entries
    |> Enum.chunk_every(chunk_size)
    |> insert_chunks(repo, source, insert_opts, max_concurrency)
  end

  def table(prefix, name), do: ~s("#{prefix}_#{name}")

  def query(repo, sql, params \\ []), do: Ecto.Adapters.SQL.query(repo, sql, params)

  defp insert_chunks([], _repo, _source, _opts, _max_concurrency), do: :ok

  defp insert_chunks([chunk], repo, source, opts, _max_concurrency) do
    repo.insert_all(source, chunk, opts)
    :ok
  end

  defp insert_chunks(chunks, repo, source, opts, max_concurrency) do
    chunks
    |> Task.async_stream(
      fn chunk -> repo.insert_all(source, chunk, opts) end,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.each(fn
      {:ok, _result} -> :ok
      {:exit, reason} -> exit(reason)
    end)
  end

  defp repo_pool_size(repo) do
    repo.config()
    |> Keyword.get(:exograph_bulk_concurrency, 2)
    |> min(System.schedulers_online())
    |> max(1)
  end
end
