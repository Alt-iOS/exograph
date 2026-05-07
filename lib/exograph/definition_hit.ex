defmodule Exograph.DefinitionHit do
  @moduledoc "Definition search hit."

  @type t :: %__MODULE__{
          definition: Exograph.Definition.t() | nil,
          fragment: Exograph.Fragment.t() | nil,
          score: number(),
          match: term()
        }

  defstruct definition: nil, fragment: nil, score: 0.0, match: nil

  def new(attrs), do: struct(__MODULE__, attrs)
end
