defmodule Exograph.Web.APIController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query

  alias Exograph.Web.{QueryExecutor, SearchResult}
  alias Exograph.Postgres.Options

  def search(conn, params) do
    index = index()
    pattern = params["pattern"] || ""
    mode = params["mode"] || "structural"
    limit = parse_limit(params["limit"])
    skip = decode_cursor(params["cursor"])
    package_id = params["package_id"]

    opts = [limit: limit, skip: skip] ++ scope_opts(package_id)

    {elapsed_us, result} =
      :timer.tc(fn ->
        case mode do
          "text" ->
            Exograph.search_text(index, pattern, opts)

          "regex" ->
            case Regex.compile(pattern) do
              {:ok, regex} -> Exograph.search_text(index, regex, opts)
              {:error, reason} -> {:error, "Invalid regex: #{inspect(reason)}"}
            end

          _ ->
            Exograph.search(index, pattern, opts)
        end
      end)

    case result do
      {:ok, hits} ->
        next_cursor = if length(hits) == limit, do: encode_cursor(skip + limit), else: nil

        json(conn, %{
          results: Enum.map(hits, &serialize_result/1),
          count: length(hits),
          elapsed_ms: Float.round(elapsed_us / 1000, 1),
          next_cursor: next_cursor
        })

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  def query(conn, params) do
    index = index()
    query_string = params["query"] || ""
    skip = decode_cursor(params["cursor"])

    case QueryExecutor.execute(index, query_string, skip: skip) do
      {:ok, hits, elapsed_ms, effective_limit, _total} ->
        next_cursor =
          if length(hits) >= effective_limit, do: encode_cursor(skip + effective_limit), else: nil

        json(conn, %{
          results: Enum.map(hits, &serialize_result/1),
          count: length(hits),
          elapsed_ms: elapsed_ms,
          next_cursor: next_cursor
        })

      {:error, message} ->
        conn |> put_status(400) |> json(%{error: message})
    end
  end

  def packages(conn, _params) do
    prefix = Application.get_env(:exograph, :web_prefix)
    repo = Application.get_env(:exograph, :web_repo)

    packages =
      from(p in {"#{prefix}_packages", Exograph.Postgres.PackageRecord},
        left_join: f in ^Options.fragments_source(prefix),
        on: true,
        where: fragment("? = ?", f.package_id, p.id),
        group_by: [p.id, p.name],
        order_by: [desc: count(f.id)],
        select: %{id: p.id, name: p.name, fragments: count(f.id)}
      )
      |> repo.all(timeout: 30_000)

    json(conn, %{packages: packages, total: length(packages)})
  end

  def stats(conn, _params) do
    prefix = Application.get_env(:exograph, :web_prefix)
    repo = Application.get_env(:exograph, :web_repo)

    counts =
      for table <-
            ~w(packages package_versions files fragments fragment_terms definitions references comments call_edges terms),
          into: %{} do
        {:ok, %{rows: [[count]]}} =
          Ecto.Adapters.SQL.query(repo, "SELECT count(*) FROM #{prefix}_#{table}", [],
            timeout: 30_000
          )

        {table, count}
      end

    json(conn, Map.put(counts, "prefix", prefix))
  end

  defp index, do: Application.get_env(:exograph, :web_index)

  defp encode_cursor(offset) when is_integer(offset),
    do: Base.url_encode64("#{offset}", padding: false)

  defp decode_cursor(nil), do: 0
  defp decode_cursor(""), do: 0

  defp decode_cursor(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} -> String.to_integer(decoded)
      :error -> 0
    end
  end

  defp parse_limit(nil), do: 50
  defp parse_limit(n) when is_integer(n), do: min(n, 200)
  defp parse_limit(s) when is_binary(s), do: s |> String.to_integer() |> min(200)

  defp scope_opts(nil), do: []
  defp scope_opts(id) when is_integer(id), do: [package_id: id]

  defp scope_opts(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> [package_id: int]
      _ -> []
    end
  end

  defp serialize_result(hit) do
    r = SearchResult.from(hit)

    %{
      type: r.type,
      file: r.file,
      package: r.package,
      module: r.module,
      kind: r.kind,
      name: r.name,
      arity: r.arity,
      line: r.line,
      joined: r.joined_label
    }
  end
end
