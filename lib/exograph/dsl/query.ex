defmodule Exograph.DSL.Query do
  @moduledoc """
  Query IR produced by `Exograph.DSL`.
  """

  @type source :: :fragment | :definition | :reference | :call_edge

  @type predicate ::
          {:matches, atom(), String.t()}
          | {:contains, atom(), String.t()}
          | {:prefix_search, atom(), atom(), String.t()}
          | {:eq, atom(), atom(), term()}
          | {:cmp, atom(), atom(), :> | :< | :>= | :<=, term()}
          | {:in, atom(), atom(), [term()]}

  @type join :: {:assoc, atom(), atom(), atom()}

  @type select :: nil | atom() | {:tuple, [atom()]}

  @type t :: %__MODULE__{
          source: source(),
          binding: atom(),
          predicates: [predicate()],
          joins: [join()],
          select: select()
        }

  defstruct [:source, :binding, :select, predicates: [], joins: []]
end
