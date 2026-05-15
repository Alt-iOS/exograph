defmodule Exograph.DSL.Executor.Scope do
  @moduledoc false

  import Ecto.Query

  alias Exograph.DSL.Compiler
  alias Exograph.InvertedIndex.Postgres, as: PostgresInvertedIndex

  @doc false
  def where_fragment_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_fragment_package(package_id)
    |> maybe_where_fragment_package_version(package_version_id)
  end

  @doc false
  def maybe_where_fragment_package(queryable, nil), do: queryable

  def maybe_where_fragment_package(queryable, package_id),
    do: where(queryable, [fragment], fragment.package_id == ^package_id)

  @doc false
  def maybe_where_fragment_package_version(queryable, nil), do: queryable

  def maybe_where_fragment_package_version(queryable, package_version_id),
    do: where(queryable, [fragment], fragment.package_version_id == ^package_version_id)

  @doc false
  def where_fragment_scope_second(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_second_package(package_id)
    |> maybe_where_second_package_version(package_version_id)
  end

  @doc false
  def maybe_where_second_package(queryable, nil), do: queryable

  def maybe_where_second_package(queryable, package_id),
    do: where(queryable, [_first, fragment], fragment.package_id == ^package_id)

  @doc false
  def maybe_where_second_package_version(queryable, nil), do: queryable

  def maybe_where_second_package_version(queryable, package_version_id),
    do: where(queryable, [_first, fragment], fragment.package_version_id == ^package_version_id)

  @doc false
  def where_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_package(package_id)
    |> maybe_where_package_version(package_version_id)
  end

  @doc false
  def maybe_where_package(queryable, nil), do: queryable

  def maybe_where_package(queryable, package_id),
    do: where(queryable, [row], row.package_id == ^package_id)

  @doc false
  def maybe_where_package_version(queryable, nil), do: queryable

  def maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [row], row.package_version_id == ^package_version_id)

  @doc false
  def where_structural_terms(queryable, index, plan) do
    case resolve_structural_term_ids(index, plan) do
      [] -> queryable
      ids -> where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^ids))
    end
  end

  @doc false
  def where_structural_terms_second(queryable, index, plan) do
    case resolve_structural_term_ids(index, plan) do
      [] -> queryable
      ids -> where(queryable, [_first, fragment], fragment("? @> ?", fragment.terms, ^ids))
    end
  end

  defp resolve_structural_term_ids(index, plan) do
    required_terms = Compiler.required_terms(plan.query)

    if required_terms == [] do
      []
    else
      PostgresInvertedIndex.resolve_term_ids(index.inverted, required_terms)
    end
  end
end
