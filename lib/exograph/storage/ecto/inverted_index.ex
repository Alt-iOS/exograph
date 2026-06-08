defmodule Exograph.Storage.Ecto.InvertedIndex do
  @moduledoc """
  Ecto candidate retrieval backend with backend-specific text-search paths.

  Structural lookups use the `terms integer[]` GIN index. Term strings are
  normalized to integer IDs in the terms table before querying.
  """

  import Ecto.Query

  alias Exograph.{Hit, Package, PackageVersion}
  alias Exograph.Storage.Ecto.{CallEdgeRecord, FactQuery, FragmentRecord, Options}
  alias Exograph.StructuralQuery

  defstruct repo: nil, prefix: "exograph", package: nil, package_version: nil, bm25?: true

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          package: Package.t() | nil,
          package_version: PackageVersion.t() | nil,
          bm25?: boolean()
        }

  def new(opts \\ []), do: {:ok, Options.store(__MODULE__, opts)}

  def add(%__MODULE__{} = index, fragments) when is_list(fragments) do
    {:ok, index}
  end

  def search(%__MODULE__{} = index, %StructuralQuery{} = query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    required = MapSet.to_list(query.required_terms)
    optional = MapSet.to_list(query.optional_terms)

    required_ids = resolve_term_ids(index, required)
    optional_ids = resolve_term_ids(index, optional)

    required_id_set = MapSet.new(required_ids)
    optional_id_set = MapSet.new(optional_ids)

    records =
      base_query(index)
      |> where_term_ids(index, required_ids, optional_ids)
      |> where_scope(opts)
      |> limit(^limit)
      |> with_file(index, include_source?(query))
      |> index.repo.all()

    hits = Enum.map(records, &hit(&1, query, required_id_set, optional_id_set))
    {:ok, hits}
  end

  def search_text(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    search_file_field(index, literal, :source, opts)
  end

  def search_comments(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    search_file_field(index, literal, :comments_text, opts)
  end

  def search_definitions(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    FactQuery.search(index, definitions_source(index), literal, opts)
  end

  def search_references(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    FactQuery.search(index, references_source(index), literal, opts)
  end

  def search_callers(%__MODULE__{} = index, callee, opts \\ []) when is_binary(callee) do
    search_call_edges(index, :callee_qualified_name, callee, opts)
  end

  def search_callees(%__MODULE__{} = index, caller, opts \\ []) when is_binary(caller) do
    search_call_edges(index, :caller_qualified_name, caller, opts)
  end

  defp search_call_edges(index, field, literal, opts) do
    limit = Keyword.get(opts, :limit, 50)

    records =
      from(edge in call_edges_source(index),
        where: field(edge, ^field) == ^literal or ilike(field(edge, ^field), ^"%#{literal}%"),
        order_by: [asc: edge.file_id, asc: edge.line, asc: edge.id],
        limit: ^limit
      )
      |> where_scope(opts)
      |> index.repo.all()

    {:ok, Enum.map(records, &CallEdgeRecord.to_call_edge/1)}
  end

  def resolve_term_ids(_index, []), do: []

  def resolve_term_ids(index, terms) when is_list(terms) do
    from(t in Options.terms_source(index.prefix), where: t.term in ^terms, select: t.id)
    |> index.repo.all(timeout: :infinity)
  rescue
    _ -> []
  end

  defp include_source?(%StructuralQuery{verifier: {:selector, _selector}} = query),
    do: StructuralQuery.requires_source?(query)

  defp include_source?(_query), do: true

  def search_text_regex(%__MODULE__{} = index, %Regex{source: pattern}, opts) do
    limit = Keyword.get(opts, :limit, 50)
    files = files_source(index)

    query =
      from(fragment in {source(index), FragmentRecord},
        join: file in ^files,
        on: file.id == fragment.file_id,
        where: fragment("? ~* ?", file.source, ^pattern),
        order_by: [asc: file.path, asc: fragment.line],
        limit: ^limit,
        select: {fragment, file.source, file.path}
      )
      |> where_scope(opts)

    hits =
      index.repo.all(query, timeout: 30_000)
      |> Enum.map(fn {record, source, path} ->
        Hit.new(fragment: Options.hydrate_fragment(record, source, path), score: 1.0)
      end)

    {:ok, hits}
  end

  defp search_file_field(index, literal, :source, opts) do
    if duckdb?(index) do
      duckdb_file_search(index, literal, :source, opts)
    else
      file_search(
        index,
        literal,
        opts,
        fn files_source, limit ->
          source_search_query(index, files_source, literal, limit, match_operator(opts))
        end,
        fn files_source, limit ->
          source_ilike_query(index, files_source, literal, limit)
        end
      )
    end
  end

  defp search_file_field(index, literal, :comments_text, opts) do
    if duckdb?(index) do
      duckdb_file_search(index, literal, :comments_text, opts)
    else
      file_search(
        index,
        literal,
        opts,
        fn files_source, limit ->
          comments_search_query(index, files_source, literal, limit, match_operator(opts))
        end,
        fn files_source, limit ->
          comments_ilike_query(index, files_source, literal, limit)
        end
      )
    end
  end

  defp source_search_query(index, _files_source, literal, limit, :all) do
    file_to_fragment_query(
      index,
      limit,
      dynamic([file: f], fragment("?::pdb.source_code &&& ?", f.source, ^literal)),
      dynamic([file: f], fragment("pdb.score(?) DESC", f.id))
    )
  end

  defp source_search_query(index, _files_source, literal, limit, :any) do
    file_to_fragment_query(
      index,
      limit,
      dynamic([file: f], fragment("?::pdb.source_code ||| ?", f.source, ^literal)),
      dynamic([file: f], fragment("pdb.score(?) DESC", f.id))
    )
  end

  defp comments_search_query(index, _files_source, literal, limit, :all) do
    file_to_fragment_query(
      index,
      limit,
      dynamic([file: f], fragment("?::pdb.unicode_words &&& ?", f.comments_text, ^literal)),
      dynamic([file: f], fragment("pdb.score(?) DESC", f.id))
    )
  end

  defp comments_search_query(index, _files_source, literal, limit, :any) do
    file_to_fragment_query(
      index,
      limit,
      dynamic([file: f], fragment("?::pdb.unicode_words ||| ?", f.comments_text, ^literal)),
      dynamic([file: f], fragment("pdb.score(?) DESC", f.id))
    )
  end

  defp source_ilike_query(index, _files_source, literal, limit) do
    pattern = "%#{escape_like(literal)}%"

    file_to_fragment_query(index, limit, dynamic([file: f], ilike(f.source, ^pattern)))
    |> order_by([file: f], asc: f.path)
  end

  defp comments_ilike_query(index, _files_source, literal, limit) do
    pattern = "%#{escape_like(literal)}%"

    file_to_fragment_query(index, limit, dynamic([file: f], ilike(f.comments_text, ^pattern)))
    |> order_by([file: f], asc: f.path)
  end

  defp file_to_fragment_query(index, limit, where_clause, order_clause \\ nil) do
    fragments_source = source(index)
    files_source = files_source(index)

    first_fragment =
      from(fr in {fragments_source, FragmentRecord},
        where: fr.file_id == parent_as(:file).id,
        order_by: [asc: fr.line],
        limit: 1
      )

    q =
      from(f in files_source,
        as: :file,
        inner_lateral_join: fr in subquery(first_fragment),
        on: true,
        where: ^where_clause,
        limit: ^limit,
        select: {fr, f.source, f.path}
      )

    if order_clause, do: order_by(q, ^order_clause), else: q
  end

  defp duckdb_file_search(index, literal, field, opts) do
    limit = Keyword.get(opts, :limit, 50)

    if index.bm25? do
      duckdb_bm25_file_search(index, literal, field, limit)
    else
      duckdb_ilike_file_search(index, literal, field, limit)
    end
  end

  defp duckdb_bm25_file_search(index, literal, field, limit) do
    {files_table, _schema} = files_source(index)
    schema = QuackDB.FTS.schema_name("main.#{files_table}")
    field_name = Atom.to_string(field)

    sql = """
    WITH matched_files AS (
      SELECT
        id,
        source,
        path,
        "#{schema}".match_bm25(id, ?, fields := '#{field_name}') AS score
      FROM #{Exograph.Postgres.table(index.prefix, "files")}
      WHERE "#{schema}".match_bm25(id, ?, fields := '#{field_name}') > 0
      ORDER BY score DESC, path ASC
      LIMIT ?
    )
    #{duckdb_first_fragment_sql(index.prefix)}
    ORDER BY matched_files.score DESC, matched_files.path ASC, fr.line ASC
    """

    {:ok, hits_from_duckdb_rows(index.repo.query!(sql, [literal, literal, limit]).rows)}
  rescue
    _ in [QuackDB.Error, Ecto.QueryError] ->
      duckdb_ilike_file_search(index, literal, field, limit)
  end

  defp duckdb_ilike_file_search(index, literal, field, limit) do
    column = Atom.to_string(field)
    pattern = "%#{escape_like(literal)}%"

    sql = """
    WITH matched_files AS (
      SELECT id, source, path
      FROM #{Exograph.Postgres.table(index.prefix, "files")}
      WHERE "#{column}" ILIKE ?
      ORDER BY path ASC
      LIMIT ?
    )
    #{duckdb_first_fragment_sql(index.prefix)}
    ORDER BY matched_files.path ASC, fr.line ASC
    """

    {:ok, hits_from_duckdb_rows(index.repo.query!(sql, [pattern, limit]).rows)}
  end

  defp duckdb_first_fragment_sql(prefix) do
    """
    SELECT
      fr.id, fr.package_id, fr.package_version_id, fr.file_id, fr.content_hash, fr.ast,
      fr.kind, fr.module, fr.name, fr.arity, fr.line, fr.end_line, fr.mass,
      fr.exact_hash, fr.terms, fr.sub_hashes, fr.inserted_at, fr.updated_at,
      matched_files.source, matched_files.path
    FROM matched_files
    INNER JOIN LATERAL (
      SELECT
        id, package_id, package_version_id, file_id, content_hash, ast,
        kind, module, name, arity, line, end_line, mass,
        exact_hash, terms, sub_hashes, inserted_at, updated_at
      FROM #{Exograph.Postgres.table(prefix, "fragments")}
      WHERE file_id = matched_files.id
      ORDER BY line ASC
      LIMIT 1
    ) AS fr ON true
    """
  end

  defp hits_from_duckdb_rows(rows) do
    Enum.map(rows, fn row ->
      {record, source, path} = duckdb_fragment_record(row)
      Hit.new(fragment: Options.hydrate_fragment(record, source, path), score: 1.0)
    end)
  end

  defp duckdb_fragment_record([
         id,
         package_id,
         package_version_id,
         file_id,
         content_hash,
         ast,
         kind,
         module,
         name,
         arity,
         line,
         end_line,
         mass,
         exact_hash,
         terms,
         sub_hashes,
         inserted_at,
         updated_at,
         source,
         path
       ]) do
    {%FragmentRecord{
       id: id,
       package_id: package_id,
       package_version_id: package_version_id,
       file_id: file_id,
       content_hash: content_hash,
       ast: ast,
       kind: String.to_existing_atom(kind),
       module: module,
       name: name,
       arity: arity,
       line: line,
       end_line: end_line,
       mass: mass,
       exact_hash: exact_hash,
       terms: terms || [],
       sub_hashes: sub_hashes || [],
       inserted_at: inserted_at,
       updated_at: updated_at
     }, source, path}
  end

  defp duckdb?(index), do: Exograph.Backend.duckdb_repo?(index.repo)

  defp escape_like(str), do: str |> String.replace("%", "\\%") |> String.replace("_", "\\_")

  defp match_operator(opts) do
    case Keyword.get(opts, :match, :any) do
      :all -> :all
      _other -> :any
    end
  end

  defp file_search(index, _literal, opts, bm25_fun, ilike_fun) do
    limit = Keyword.get(opts, :limit, 50)
    files = files_source(index)

    query =
      try do
        q = bm25_fun.(files, limit) |> where_scope(opts)
        index.repo.all(q)
      rescue
        _ in [Postgrex.Error, QuackDB.Error, Ecto.QueryError] ->
          q = ilike_fun.(files, limit) |> where_scope(opts)
          index.repo.all(q)
      end

    hits =
      Enum.map(query, fn {record, source, path} ->
        Hit.new(fragment: Options.hydrate_fragment(record, source, path), score: 1.0)
      end)

    {:ok, hits}
  end

  defp with_file(queryable, index, true) do
    from(fragment in queryable,
      left_join: file in ^files_source(index),
      on: file.id == fragment.file_id,
      select: {fragment, file.source, file.path}
    )
  end

  defp with_file(queryable, index, false) do
    from(fragment in queryable,
      left_join: file in ^files_source(index),
      on: file.id == fragment.file_id,
      select: {fragment, nil, file.path}
    )
  end

  defp base_query(index) do
    from(fragment in {source(index), FragmentRecord},
      order_by: [desc: fragment.mass, asc: fragment.file_id, asc: fragment.line]
    )
  end

  defp where_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)
    package_version_id = Keyword.get(opts, :package_version_id)
    package_version = Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_package(package_id)
    |> maybe_where_package_version(package_version_id || package_version)
  end

  defp maybe_where_package(queryable, nil), do: queryable

  defp maybe_where_package(queryable, package_id),
    do: where(queryable, [fragment], fragment.package_id == ^package_id)

  defp maybe_where_package_version(queryable, nil), do: queryable

  defp maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [fragment], fragment.package_version_id == ^package_version_id)

  defp where_term_ids(queryable, _index, [], []), do: queryable

  defp where_term_ids(queryable, index, required_ids, []) when required_ids != [] do
    if duckdb?(index) do
      join_required_term_candidates(queryable, index, required_ids)
    else
      where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^required_ids))
    end
  end

  defp where_term_ids(queryable, index, [], optional_ids) when optional_ids != [] do
    if duckdb?(index) do
      candidates = duckdb_any_term_candidates(index, optional_ids)

      join(queryable, :inner, [fragment], candidate in subquery(candidates),
        on: candidate.fragment_id == fragment.id
      )
    else
      where(queryable, [fragment], fragment("? && ?", fragment.terms, ^optional_ids))
    end
  end

  defp where_term_ids(queryable, index, required_ids, _optional_ids) do
    if duckdb?(index) do
      join_required_term_candidates(queryable, index, required_ids)
    else
      where(queryable, [fragment], fragment("? @> ?", fragment.terms, ^required_ids))
    end
  end

  defp join_required_term_candidates(queryable, index, required_ids) do
    candidates = duckdb_required_term_candidates(index, required_ids)

    join(queryable, :inner, [fragment], candidate in subquery(candidates),
      on: candidate.fragment_id == fragment.id
    )
  end

  defp duckdb_required_term_candidates(index, ids) do
    required_count = length(ids)

    from(term in Options.fragment_terms_source(index.prefix),
      where: term.term_id in ^ids,
      group_by: term.fragment_id,
      having: count(term.term_id, :distinct) == ^required_count,
      select: term.fragment_id
    )
  end

  defp duckdb_any_term_candidates(index, ids) do
    from(term in Options.fragment_terms_source(index.prefix),
      where: term.term_id in ^ids,
      distinct: term.fragment_id,
      select: term.fragment_id
    )
  end

  defp hit({%FragmentRecord{} = record, source, path}, _query, required_id_set, optional_id_set) do
    fragment = Options.hydrate_fragment(record, source, path)
    required_matches = MapSet.intersection(fragment.terms, required_id_set)
    optional_matches = MapSet.intersection(fragment.terms, optional_id_set)

    Hit.new(
      fragment: fragment,
      score: MapSet.size(required_matches) * 10 + MapSet.size(optional_matches),
      matched_terms: required_matches |> MapSet.union(optional_matches) |> MapSet.to_list()
    )
  end

  defp files_source(index), do: Options.files_source(index.prefix)
  defp definitions_source(index), do: Options.definitions_source(index.prefix)
  defp references_source(index), do: Options.references_source(index.prefix)
  defp call_edges_source(index), do: Options.call_edges_source(index.prefix)
  defp source(index), do: Options.fragments_source(index.prefix)
end
