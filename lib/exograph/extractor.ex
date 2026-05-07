defmodule Exograph.Extractor do
  @moduledoc """
  Extracts indexable Exograph facts from source inputs.

  Extractors are the boundary between language/analysis engines and Exograph's
  Postgres persistence layer. The built-in `Exograph.Extractor.ExAST` extractor
  owns Elixir AST fragments and ExAST-derived facts; future extractors can add
  semantic facts such as Reach call graphs, control-flow edges, or data-flow
  edges.
  """

  @type paths :: String.t() | [String.t()]
  @type item :: Exograph.Fragment.t() | struct()

  @callback index_paths(paths(), keyword()) :: [item()]
  @callback stream_paths(paths(), keyword()) :: Enumerable.t()
end
