defmodule Exograph.DSL.Query do
  @moduledoc """
  Query IR produced by `Exograph.DSL`.
  """

  @type source :: :fragment
  @type predicate :: {:matches, atom(), String.t()} | {:contains, atom(), String.t()}

  @type t :: %__MODULE__{
          source: source(),
          binding: atom(),
          predicates: [predicate()]
        }

  defstruct [:source, :binding, predicates: []]
end
