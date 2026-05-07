defmodule Exograph.DSL.Plan.Join do
  @moduledoc false

  @type t :: %__MODULE__{
          parent: atom(),
          binding: atom(),
          assoc: atom(),
          source: Exograph.DSL.Query.source(),
          position: pos_integer()
        }

  defstruct [:parent, :binding, :assoc, :source, :position]
end
