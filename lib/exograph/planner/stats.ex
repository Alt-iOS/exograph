defmodule Exograph.Planner.Stats do
  @moduledoc false

  alias Exograph.Index

  @type t :: %__MODULE__{
          fragment_count: non_neg_integer(),
          term_doc_freq: %{optional(String.t()) => non_neg_integer()}
        }

  defstruct fragment_count: 0, term_doc_freq: %{}

  @spec collect(Index.t(), Exograph.Query.t() | nil) :: t()
  def collect(%Index{} = index, query \\ nil) do
    terms = query_terms(query)

    %__MODULE__{
      fragment_count: index.fragment_store_backend.count(index.fragment_store),
      term_doc_freq: index.fragment_store_backend.term_frequencies(index.fragment_store, terms)
    }
  end

  defp query_terms(nil), do: []

  defp query_terms(query) do
    query.candidate_groups
    |> Enum.reduce(MapSet.union(query.required_terms, query.optional_terms), &MapSet.union/2)
    |> MapSet.to_list()
  end

  @spec estimate_terms(t(), Enumerable.t()) :: non_neg_integer() | :unknown
  def estimate_terms(%__MODULE__{} = stats, terms) do
    terms = Enum.to_list(terms)

    cond do
      terms == [] ->
        stats.fragment_count

      stats.term_doc_freq == %{} ->
        :unknown

      true ->
        least_frequent_term = Enum.min_by(terms, &Map.get(stats.term_doc_freq, &1, 0))
        Map.get(stats.term_doc_freq, least_frequent_term, 0)
    end
  end
end
