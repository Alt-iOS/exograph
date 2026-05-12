defmodule Exograph.TreeStore do
  @moduledoc false

  alias Exograph.Fragment
  alias Exograph.Tree.Node

  @type store :: term()

  @callback new(keyword()) :: {:ok, store()} | {:error, term()}
  @callback put_fragments(store(), [Fragment.t()]) :: {:ok, store()} | {:error, term()}
  @callback nodes(store(), Fragment.id()) :: [Node.t()]
end
