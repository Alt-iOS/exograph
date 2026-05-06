defmodule Exograph.FragmentStore do
  @moduledoc """
  Fragment storage backend contract.
  """

  alias Exograph.Fragment

  @type store :: term()

  @callback new(keyword()) :: {:ok, store()} | {:error, term()}
  @callback put(store(), [Fragment.t()]) :: {:ok, store()} | {:error, term()}
  @callback get(store(), Fragment.id()) :: {:ok, Fragment.t()} | :error
  @callback all(store()) :: [Fragment.t()]
end
