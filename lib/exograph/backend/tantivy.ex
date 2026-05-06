defmodule Exograph.Backend.Tantivy do
  @moduledoc """
  TantivyEx inverted-index profile with in-memory fragment and tree stores.
  """

  @behaviour Exograph.Backend

  alias Exograph.Backend
  alias Exograph.InvertedIndex.TantivyEx

  @impl true
  def config(opts) do
    path = Keyword.get(opts, :index_path, ".exograph/tantivy")

    Backend.memory_config()
    |> Keyword.put(:inverted, TantivyEx)
    |> Keyword.put(:inverted_opts, path: path)
  end
end
