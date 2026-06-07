defmodule Exograph.ShardedIndex do
  @moduledoc """
  Runtime handle for an index split across multiple independent Exograph indexes.

  Shards keep local IDs. Query APIs fan out to every shard and merge results in
  memory, so callers can use the same high-level search functions without first
  materializing one merged DuckDB database.
  """

  alias Exograph.Index

  @type shard :: Index.t()

  @type t :: %__MODULE__{
          shards: [shard()]
        }

  defstruct shards: []

  @spec new([Index.t()]) :: t()
  def new(shards) when is_list(shards), do: %__MODULE__{shards: shards}
end
