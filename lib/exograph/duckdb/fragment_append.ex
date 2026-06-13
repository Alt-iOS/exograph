defmodule Exograph.DuckDB.FragmentAppend do
  @moduledoc false

  def insert_by_hash(_repo, _source, _schema, []), do: %{}

  def insert_by_hash(repo, source, schema, entries) do
    target = {source, schema}

    rows =
      entries
      |> Enum.reject(&is_nil(&1.content_hash))
      |> Enum.uniq_by(& &1.content_hash)

    if rows == [] do
      %{}
    else
      {_count, returning} =
        Exograph.Hex.StageTimings.measure(:fragment_append_rows, fn ->
          repo.insert_all(target, rows,
            insert_method: :append,
            chunk_every: 2_000,
            conflict_target: [:content_hash],
            on_conflict: :nothing,
            returning: [:id, :content_hash],
            timeout: :infinity
          )
        end)

      Map.new(returning, fn row -> {row.content_hash, row.id} end)
    end
  end
end
