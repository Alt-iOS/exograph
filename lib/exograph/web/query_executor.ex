defmodule Exograph.Web.QueryExecutor do
  @moduledoc false

  import Exograph.DSL
  @eval_env __ENV__

  @default_limit 100

  def default_limit, do: @default_limit

  def execute(index, query_string, opts \\ []) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        case parse_and_eval(query_string) do
          {:ok, parsed} -> run_parsed(index, parsed, opts)
          {:error, _} = error -> error
        end
      end)

    case result do
      {:ok, results, limit} -> {:ok, results, Float.round(elapsed_us / 1000, 1), limit}
      {:ok, results} -> {:ok, results, Float.round(elapsed_us / 1000, 1), @default_limit}
      {:error, error} -> {:error, error}
    end
  end

  defp parse_and_eval(query_string) do
    case Code.string_to_quoted(query_string, file: "query", columns: true) do
      {:ok, _ast} ->
        eval_with_diagnostics(query_string)

      {:error, {location, msg_info, token}} ->
        line = if is_list(location), do: Keyword.get(location, :line, 1), else: location
        col = if is_list(location), do: Keyword.get(location, :column, 1), else: 1
        message = format_parse_error(msg_info, token)
        {:error, %{message: message, markers: [%{line: line, column: col, message: message}]}}
    end
  end

  defp eval_with_diagnostics(query_string) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {parsed, _bindings} = Code.eval_string(query_string, [], eval_env())
          {:ok, parsed}
        rescue
          e -> {:error, e}
        end
      end)

    case result do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, exception} ->
        error_diags = Enum.filter(diagnostics, &(&1.severity == :error))

        if error_diags != [] do
          markers =
            Enum.map(error_diags, fn diag ->
              line = extract_eval_line(diag, query_string)
              %{line: line, column: 1, message: diag.message}
            end)

          {:error, %{message: hd(error_diags).message, markers: markers}}
        else
          {:error, format_error(exception)}
        end
    end
  end

  defp extract_eval_line(diag, query_string) do
    cond do
      is_integer(diag.position) and diag.position > 0 ->
        diag.position

      match?({line, _col} when is_integer(line), diag.position) ->
        elem(diag.position, 0)

      true ->
        guess_line_from_message(diag.message, query_string)
    end
  end

  defp guess_line_from_message(message, query_string) do
    case Regex.run(~r/\"(\w+)\"/, message) do
      [_, token] ->
        query_string
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.find_value(1, fn {line, num} ->
          if String.contains?(line, token), do: num
        end)

      _ ->
        1
    end
  end

  defp format_parse_error({msg, extra}, token) when is_binary(msg) and is_binary(extra),
    do: "#{msg}#{extra}#{token}"

  defp format_parse_error(msg, token) when is_binary(msg), do: "#{msg}#{token}"

  defp eval_env, do: @eval_env

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

  defp format_error(%CompileError{line: line, description: desc}) do
    %{message: desc, markers: [%{line: line || 1, column: 1, message: desc}]}
  end

  defp format_error(%SyntaxError{line: line, column: col, description: desc}) do
    %{message: desc, markers: [%{line: line || 1, column: col || 1, message: desc}]}
  end

  defp format_error(%TokenMissingError{line: line, column: col, description: desc}) do
    %{message: desc, markers: [%{line: line || 1, column: col || 1, message: desc}]}
  end

  defp format_error(%ArgumentError{message: msg}) do
    %{message: msg, markers: [%{line: 1, column: 1, message: msg}]}
  end

  defp format_error(error) do
    msg = Exception.message(error)
    %{message: msg, markers: []}
  end
end
