defmodule Exograph.Planner.Stats do
  @moduledoc """
  Lightweight statistics used by the planner.
  """

  alias Exograph.Index

  @type t :: %__MODULE__{
          fragment_count: non_neg_integer(),
          term_doc_freq: %{optional(String.t()) => non_neg_integer()}
        }

  defstruct fragment_count: 0, term_doc_freq: %{}

  @spec collect(Index.t()) :: t()
  def collect(%Index{} = index) do
    fragments = index.fragment_store_backend.all(index.fragment_store)

    term_doc_freq =
      fragments
      |> Enum.reduce(%{}, fn fragment, acc ->
        Enum.reduce(fragment.terms, acc, fn term, acc ->
          Map.update(acc, term, 1, &(&1 + 1))
        end)
      end)

    %__MODULE__{fragment_count: length(fragments), term_doc_freq: term_doc_freq}
  end

  @spec estimate_terms(t(), Enumerable.t()) :: non_neg_integer() | :unknown
  def estimate_terms(%__MODULE__{} = stats, terms) do
    terms = Enum.to_list(terms)

    cond do
      terms == [] -> stats.fragment_count
      stats.term_doc_freq == %{} -> :unknown
      true -> terms |> Enum.map(&Map.get(stats.term_doc_freq, &1, 0)) |> Enum.min()
    end
  end
end
