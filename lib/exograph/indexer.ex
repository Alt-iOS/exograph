defmodule Exograph.Indexer do
  @moduledoc """
  Compatibility wrapper around `Exograph.Extractor.ExAST`.
  """

  alias Exograph.Extractor.ExAST

  @spec index_paths(String.t() | [String.t()], keyword()) :: [Exograph.Fragment.t()]
  defdelegate index_paths(paths, opts \\ []), to: ExAST

  @spec stream_paths(String.t() | [String.t()], keyword()) :: Enumerable.t()
  defdelegate stream_paths(paths, opts \\ []), to: ExAST

  @spec index_file(String.t(), keyword()) :: [Exograph.Fragment.t()]
  defdelegate index_file(file, opts \\ []), to: ExAST
end
