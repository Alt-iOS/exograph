defmodule Exograph.InvertedIndex.Postgres do
  @moduledoc """
  Postgres/ParadeDB candidate retrieval backend implemented with Ecto queries.

  Structural lookups use the `terms text[]` GIN index. Text relevance fields are
  stored alongside the same rows so deployments with `pg_search` can add a BM25
  index without changing Exograph's logical verification pipeline.
  """

  @behaviour Exograph.InvertedIndex

  import Ecto.Query

  alias Exograph.Postgres
  alias Exograph.Postgres.FragmentRecord
  alias Exograph.Query, as: ExographQuery

  defstruct repo: nil, prefix: "exograph"

  @type t :: %__MODULE__{repo: module(), prefix: String.t()}

  @impl true
  def new(opts \\ []) do
    if Keyword.get(opts, :migrate?, false), do: Postgres.migrate!(opts)

    {:ok,
     %__MODULE__{repo: Postgres.fetch_repo!(opts), prefix: Keyword.get(opts, :prefix, "exograph")}}
  end

  @impl true
  def add(%__MODULE__{} = index, fragments) when is_list(fragments) do
    {:ok, store} = Exograph.FragmentStore.Postgres.new(repo: index.repo, prefix: index.prefix)
    {:ok, _store} = Exograph.FragmentStore.Postgres.put(store, fragments)
    {:ok, index}
  end

  @impl true
  def search(%__MODULE__{} = index, %ExographQuery{} = query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    required = MapSet.to_list(query.required_terms)
    optional = MapSet.to_list(query.optional_terms)

    records =
      base_query(index)
      |> where_terms(required, optional)
      |> limit(^limit)
      |> index.repo.all()

    hits = Enum.map(records, &hit(&1, query))
    {:ok, hits}
  end

  def search_text(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(fragment in {source(index), FragmentRecord},
        where: fragment("? ||| ?", fragment.source, ^literal),
        order_by: [desc: fragment("paradedb.score(?)", fragment.id)],
        limit: ^limit
      )

    hits =
      index.repo.all(query)
      |> Enum.map(fn record ->
        %{fragment: FragmentRecord.to_fragment(record), score: 1.0, matched_terms: []}
      end)

    {:ok, hits}
  end

  defp base_query(index) do
    from(fragment in {source(index), FragmentRecord},
      order_by: [desc: fragment.mass, asc: fragment.file, asc: fragment.line]
    )
  end

  defp where_terms(queryable, [], []), do: queryable

  defp where_terms(queryable, required, []) do
    where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^required))
  end

  defp where_terms(queryable, [], optional) do
    where(queryable, [fragment], fragment("? && ?", fragment.terms, ^optional))
  end

  defp where_terms(queryable, required, _optional) do
    where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^required))
  end

  defp hit(%FragmentRecord{} = record, query) do
    fragment = FragmentRecord.to_fragment(record)
    required_matches = MapSet.intersection(fragment.terms, query.required_terms)
    optional_matches = MapSet.intersection(fragment.terms, query.optional_terms)

    %{
      fragment: fragment,
      score: MapSet.size(required_matches) * 10 + MapSet.size(optional_matches),
      matched_terms: required_matches |> MapSet.union(optional_matches) |> MapSet.to_list()
    }
  end

  defp source(index), do: "#{index.prefix}_fragments"
end
