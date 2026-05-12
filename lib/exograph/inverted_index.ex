defmodule Exograph.InvertedIndex do
  @moduledoc false

  alias Exograph.{Hit, Query}

  @type index :: term()
  @type hit :: Hit.t()

  @callback new(keyword()) :: {:ok, index()} | {:error, term()}
  @callback add(index(), [Fragment.t()]) :: {:ok, index()} | {:error, term()}
  @callback search(index(), Query.t(), keyword()) :: {:ok, [hit()]} | {:error, term()}
end
