defmodule Exograph.Text do
  @moduledoc """
  Text-search helpers for substring/regex verification and trigram planning.
  """

  @spec trigrams(String.t()) :: MapSet.t(String.t())
  def trigrams(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.map(&Enum.join/1)
    |> MapSet.new()
  end

  @spec literal_match?(String.t(), String.t()) :: boolean()
  def literal_match?(source, literal), do: String.contains?(source, literal)

  @spec regex_match?(String.t(), Regex.t()) :: boolean()
  def regex_match?(source, %Regex{} = regex), do: Regex.match?(regex, source)
end
