defmodule Exograph.ReferenceHit do
  @moduledoc "Reference search hit."

  @type t :: %__MODULE__{
          reference: Exograph.Reference.t() | nil,
          fragment: Exograph.Fragment.t() | nil,
          score: number(),
          match: term()
        }

  defstruct reference: nil, fragment: nil, score: 0.0, match: nil

  def new(attrs), do: struct(__MODULE__, attrs)
end
