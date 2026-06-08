defmodule Exograph.DuckDB.TextSearch do
  @moduledoc false

  alias Exograph.Hit
  alias Exograph.Storage.Ecto.{FragmentRecord, Options}

  def search_file_field(index, literal, field, opts) when field in [:source, :comments_text] do
    limit = Keyword.get(opts, :limit, 50)

    if index.bm25? do
      bm25_file_search(index, literal, field, limit)
    else
      ilike_file_search(index, literal, field, limit)
    end
  end

  defp bm25_file_search(index, literal, field, limit) do
    {files_table, _schema} = Options.files_source(index.prefix)
    schema = QuackDB.FTS.schema_name("main.#{files_table}")
    field_name = Atom.to_string(field)

    statement = """
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
    #{first_fragment_statement(index.prefix)}
    ORDER BY matched_files.score DESC, matched_files.path ASC, fr.line ASC
    """

    {:ok, hits_from_rows(index.repo.query!(statement, [literal, literal, limit]).rows)}
  rescue
    _ in [QuackDB.Error, Ecto.QueryError] ->
      ilike_file_search(index, literal, field, limit)
  end

  defp ilike_file_search(index, literal, field, limit) do
    column = Atom.to_string(field)
    pattern = "%#{escape_like(literal)}%"

    statement = """
    WITH matched_files AS (
      SELECT id, source, path
      FROM #{Exograph.Postgres.table(index.prefix, "files")}
      WHERE "#{column}" ILIKE ?
      ORDER BY path ASC
      LIMIT ?
    )
    #{first_fragment_statement(index.prefix)}
    ORDER BY matched_files.path ASC, fr.line ASC
    """

    {:ok, hits_from_rows(index.repo.query!(statement, [pattern, limit]).rows)}
  end

  defp first_fragment_statement(prefix) do
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

  defp hits_from_rows(rows) do
    Enum.map(rows, fn row ->
      {record, source, path} = fragment_record(row)
      Hit.new(fragment: Options.hydrate_fragment(record, source, path), score: 1.0)
    end)
  end

  defp fragment_record([
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

  defp escape_like(value), do: value |> String.replace("%", "\\%") |> String.replace("_", "\\_")
end
