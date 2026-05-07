defmodule Exograph.Indexer do
  @moduledoc """
  Compatibility wrapper around `Exograph.Extractor.ExAST`.
  """

  alias Exograph.Extractor.ExAST

  @spec index_paths(String.t() | [String.t()], keyword()) :: [Exograph.Fragment.t()]
  def index_paths(paths, opts \\ []), do: ExAST.index_paths(paths, opts)

  @spec stream_paths(String.t() | [String.t()], keyword()) :: Enumerable.t()
  def stream_paths(paths, opts \\ []), do: ExAST.stream_paths(paths, opts)

  @spec index_file(String.t(), keyword()) :: [Exograph.Fragment.t()]
  def index_file(file, opts \\ []), do: ExAST.index_file(file, opts)
end
