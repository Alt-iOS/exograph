defmodule Exograph.DuckDB.FragmentAppend do
  @moduledoc false

  import Ecto.Query

  def insert_by_hash(repo, source, schema, entries) do
    :global.trans(
      {{__MODULE__, repo, source, :fragments}, __MODULE__},
      fn -> locked_insert_by_hash(repo, source, schema, entries) end,
      [node()],
      1_000_000
    )
  end

  defp locked_insert_by_hash(repo, source, schema, entries) do
    target = {source, schema}
    hashes = Enum.map(entries, & &1.content_hash)
    existing = fragment_ids_by_hash(repo, source, schema, hashes)

    new_entries =
      entries
      |> Enum.reject(&Map.has_key?(existing, &1.content_hash))
      |> Enum.uniq_by(& &1.content_hash)

    inserted =
      if new_entries == [] do
        %{}
      else
        ids = allocate_ids(repo, target, length(new_entries))

        rows =
          new_entries
          |> Enum.zip(ids)
          |> Enum.map(fn {entry, id} -> Map.put(entry, :id, id) end)

        repo.insert_all(target, rows,
          insert_method: :append,
          chunk_every: 2_000,
          timeout: :infinity
        )

        Map.new(rows, fn row -> {row.content_hash, row.id} end)
      end

    Map.merge(existing, inserted)
  end

  defp fragment_ids_by_hash(repo, source, schema, hashes) do
    from(fragment in {source, schema},
      where: fragment.content_hash in ^hashes,
      select: {fragment.content_hash, fragment.id}
    )
    |> repo.all(timeout: :infinity)
    |> Map.new()
  end

  defp allocate_ids(repo, target, count) do
    sequence = QuackDB.Sequence.for_column!(repo, target, :id, timeout: :infinity)
    QuackDB.Sequence.next_values(repo, sequence, count, timeout: :infinity)
  end
end
