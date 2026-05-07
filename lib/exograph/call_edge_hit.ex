defmodule Exograph.CallEdgeHit do
  @moduledoc "Call graph edge search hit."

  @type t :: %__MODULE__{
          call_edge: Exograph.CallEdge.t(),
          score: number(),
          match: term()
        }

  defstruct call_edge: nil, score: 0.0, match: nil

  def new(attrs), do: struct(__MODULE__, attrs)
end
