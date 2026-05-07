defmodule Exograph.TextHit do
  @moduledoc "Source text search hit."

  @type t :: %__MODULE__{
          fragment: Exograph.Fragment.t(),
          score: number(),
          match: term()
        }

  defstruct fragment: nil, score: 0.0, match: nil

  def new(attrs), do: struct(__MODULE__, attrs)
end
