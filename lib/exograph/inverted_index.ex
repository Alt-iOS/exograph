defmodule Exograph.InvertedIndex do
  @moduledoc """
  Candidate retrieval backend contract.
  """

  alias Exograph.{Fragment, Query}

  @type index :: term()
  @type hit :: %{
          optional(:fragment) => Fragment.t(),
          optional(:fragment_id) => Fragment.id(),
          score: number(),
          matched_terms: [String.t()]
        }

  @callback new(keyword()) :: {:ok, index()} | {:error, term()}
  @callback add(index(), [Fragment.t()]) :: {:ok, index()} | {:error, term()}
  @callback search(index(), Query.t(), keyword()) :: {:ok, [hit()]} | {:error, term()}
end
