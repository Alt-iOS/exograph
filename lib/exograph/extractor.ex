defmodule Exograph.Extractor do
  @moduledoc false

  @type paths :: String.t() | [String.t()]
  @type item :: Exograph.Fragment.t() | struct()

  @callback index_paths(paths(), keyword()) :: [item()]
  @callback stream_paths(paths(), keyword()) :: Enumerable.t()
end
