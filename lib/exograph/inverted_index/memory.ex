defmodule Exograph.InvertedIndex.Memory do
  @moduledoc """
  In-memory inverted index used for development, tests, and backend-independent planning.
  """

  @behaviour Exograph.InvertedIndex

  alias Exograph.Query

  defstruct fragments: %{}, postings: %{}, subhash_postings: %{}

  @type t :: %__MODULE__{
          fragments: map(),
          postings: map(),
          subhash_postings: map()
        }

  @impl true
  def new(_opts \\ []), do: {:ok, %__MODULE__{}}

  @impl true
  def add(%__MODULE__{} = index, fragments) when is_list(fragments) do
    index = Enum.reduce(fragments, index, &add_fragment/2)
    {:ok, index}
  end

  @impl true
  def search(%__MODULE__{} = index, %Query{} = query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    hits =
      query
      |> candidate_ids(index)
      |> Enum.map(&score_candidate(index, &1, query))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    {:ok, hits}
  end

  defp add_fragment(fragment, %__MODULE__{} = index) do
    fragments = Map.put(index.fragments, fragment.id, fragment)

    postings =
      Enum.reduce(fragment.terms, index.postings, fn term, postings ->
        Map.update(postings, term, MapSet.new([fragment.id]), &MapSet.put(&1, fragment.id))
      end)

    subhash_postings =
      Enum.reduce(fragment.sub_hashes, index.subhash_postings, fn sub_hash, postings ->
        term = "subhash:#{sub_hash}"
        Map.update(postings, term, MapSet.new([fragment.id]), &MapSet.put(&1, fragment.id))
      end)

    %{index | fragments: fragments, postings: postings, subhash_postings: subhash_postings}
  end

  defp candidate_ids(%Query{required_terms: required, optional_terms: optional}, index) do
    required_ids = intersect_terms(index.postings, required)

    optional_ids =
      optional
      |> MapSet.to_list()
      |> Enum.map(&Map.get(index.postings, &1, MapSet.new()))
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    cond do
      MapSet.size(required) > 0 -> required_ids
      MapSet.size(optional) > 0 -> optional_ids
      true -> Map.keys(index.fragments) |> MapSet.new()
    end
  end

  defp intersect_terms(postings, terms) do
    if MapSet.size(terms) == 0 do
      MapSet.new()
    else
      terms
      |> MapSet.to_list()
      |> Enum.map(&Map.get(postings, &1, MapSet.new()))
      |> Enum.sort_by(&MapSet.size/1)
      |> case do
        [] -> MapSet.new()
        [first | rest] -> Enum.reduce(rest, first, &MapSet.intersection/2)
      end
    end
  end

  defp score_candidate(index, id, query) do
    fragment = Map.fetch!(index.fragments, id)

    required_matches = MapSet.intersection(fragment.terms, query.required_terms)
    optional_matches = MapSet.intersection(fragment.terms, query.optional_terms)
    matched_terms = MapSet.union(required_matches, optional_matches) |> MapSet.to_list()

    %{
      fragment: fragment,
      score: MapSet.size(required_matches) * 10 + MapSet.size(optional_matches),
      matched_terms: matched_terms
    }
  end
end
