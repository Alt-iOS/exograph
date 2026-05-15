defmodule Exograph.Web.QueryExecutor do
  @moduledoc false

  import Exograph.DSL
  @eval_env __ENV__

  def execute(index, query_string) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        try do
          {parsed, _bindings} = Code.eval_string(query_string, [], eval_env())
          run_parsed(index, parsed)
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case result do
      {:ok, results} -> {:ok, results, Float.round(elapsed_us / 1000, 1)}
      {:error, message} -> {:error, message}
    end
  end

  defp eval_env, do: @eval_env

  @default_limit 100

  defp run_parsed(index, %Exograph.DSL.Query{} = query) do
    limit = query.limit || @default_limit
    Exograph.all(index, query, limit: limit)
  end

  defp run_parsed(index, pattern) when is_binary(pattern) do
    Exograph.search(index, pattern, limit: @default_limit)
  end

  defp run_parsed(_index, other) do
    {:error, "Expected a DSL query or pattern string, got: #{inspect(other, limit: 200)}"}
  end
end
