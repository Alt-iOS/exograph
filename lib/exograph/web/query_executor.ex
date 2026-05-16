defmodule Exograph.Web.QueryExecutor do
  @moduledoc false

  alias Exograph.Web.SafeEval

  @default_limit 100

  def default_limit, do: @default_limit

  def execute(index, query_string, opts \\ []) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        case SafeEval.eval(query_string) do
          {:ok, parsed} -> run_parsed(index, parsed, opts)
          {:error, _} = error -> error
        end
      end)

    case result do
      {:ok, results, limit} -> {:ok, results, Float.round(elapsed_us / 1000, 1), limit}
      {:error, error} -> {:error, error}
    end
  end

  defp run_parsed(index, %Exograph.DSL.Query{} = query, opts) do
    limit = query.limit || @default_limit
    skip = Keyword.get(opts, :skip, 0)

    case Exograph.all(index, query, limit: limit, skip: skip) do
      {:ok, results} -> {:ok, results, limit}
      error -> error
    end
  end

  defp run_parsed(index, pattern, opts) when is_binary(pattern) do
    skip = Keyword.get(opts, :skip, 0)

    case Exograph.search(index, pattern, limit: @default_limit, skip: skip) do
      {:ok, results} -> {:ok, results, @default_limit}
      error -> error
    end
  end

  defp run_parsed(_index, other, _opts) do
    {:error,
     %{
       message: "Expected a DSL query or pattern string, got: #{inspect(other, limit: 200)}",
       markers: []
     }}
  end
end
