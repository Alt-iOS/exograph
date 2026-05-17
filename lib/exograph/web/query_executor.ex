defmodule Exograph.Web.QueryExecutor do
  @moduledoc false

  alias Exograph.Web.SafeEval

  @default_limit 100

  def default_limit, do: @default_limit

  def execute(index, query_string, opts \\ []) do
    mode = Keyword.get(opts, :mode, "structural")
    limit = Keyword.get(opts, :limit, @default_limit)
    skip = Keyword.get(opts, :skip, 0)

    {elapsed_us, result} =
      :timer.tc(fn ->
        case mode do
          "text" ->
            case Exograph.search_text(index, query_string, limit: limit, skip: skip) do
              {:ok, results} -> {:ok, results, limit}
              error -> error
            end

          _ ->
            case SafeEval.eval(query_string) do
              {:ok, parsed} -> run_parsed(index, parsed, limit, skip)
              {:error, _} = error -> error
            end
        end
      end)

    case result do
      {:ok, results, effective_limit} ->
        {:ok, results, Float.round(elapsed_us / 1000, 1), effective_limit}

      {:error, error} ->
        {:error, error}
    end
  end

  defp run_parsed(index, %Exograph.DSL.Query{} = query, limit, skip) do
    effective_limit = query.limit || limit

    case Exograph.all(index, query, limit: effective_limit, skip: skip) do
      {:ok, results} -> {:ok, results, effective_limit}
      error -> error
    end
  end

  defp run_parsed(index, pattern, limit, skip) when is_binary(pattern) do
    case Exograph.search(index, pattern, limit: limit, skip: skip) do
      {:ok, results} -> {:ok, results, limit}
      error -> error
    end
  end

  defp run_parsed(_index, other, _limit, _skip) do
    {:error,
     %{
       message: "Expected a DSL query or pattern string, got: #{inspect(other, limit: 200)}",
       markers: []
     }}
  end
end
