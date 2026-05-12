defmodule Exograph.FragmentStore do
  @moduledoc false

  alias Exograph.Fragment

  @type store :: term()

  @callback new(keyword()) :: {:ok, store()} | {:error, term()}
  @callback put(store(), [Fragment.t()]) :: {:ok, store()} | {:error, term()}
  @callback get(store(), Fragment.id()) :: {:ok, Fragment.t()} | :error
  @callback all(store()) :: [Fragment.t()]
  @callback count(store()) :: non_neg_integer()
  @callback page(store(), non_neg_integer(), non_neg_integer(), keyword()) :: [Fragment.t()]
  @callback term_frequencies(store(), [String.t()]) :: %{
              optional(String.t()) => non_neg_integer()
            }
end
