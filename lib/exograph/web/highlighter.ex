defmodule Exograph.Web.Highlighter do
  @moduledoc false

  def highlight(source, line, context_lines \\ 2) when is_binary(source) and is_integer(line) do
    lines = String.split(source, "\n")
    start = max(line - context_lines - 1, 0)
    finish = min(line + context_lines - 1, length(lines) - 1)

    context =
      lines
      |> Enum.with_index(1)
      |> Enum.slice(start..finish)

    highlighted_html =
      if Code.ensure_loaded?(Makeup) and Code.ensure_loaded?(Makeup.Lexers.ElixirLexer) do
        context
        |> Enum.map(fn {text, line_num} ->
          html = Makeup.highlight(text, lexer: Makeup.Lexers.ElixirLexer)
          {line_num, html, line_num == line}
        end)
      else
        Enum.map(context, fn {text, line_num} ->
          escaped = Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
          {line_num, escaped, line_num == line}
        end)
      end

    highlighted_html
  end
end
