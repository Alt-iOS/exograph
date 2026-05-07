defmodule Exograph.DSL.Query do
  @moduledoc """
  Query IR produced by `Exograph.DSL`.
  """

  @type source :: :fragment | :definition

  @type predicate ::
          {:matches, atom(), String.t()}
          | {:contains, atom(), String.t()}
          | {:prefix_search, atom(), atom(), String.t()}
          | {:eq, atom(), atom(), term()}

  @type t :: %__MODULE__{
          source: source(),
          binding: atom(),
          predicates: [predicate()]
        }

  defstruct [:source, :binding, predicates: []]
end
