defmodule Exograph.Tree.Node do
  @moduledoc false

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          fragment_id: Exograph.Fragment.id(),
          parent_id: non_neg_integer() | nil,
          ordinal: non_neg_integer(),
          role: atom() | nil,
          kind: atom(),
          label: String.t() | nil,
          line: non_neg_integer(),
          preorder: non_neg_integer(),
          postorder: non_neg_integer(),
          depth: non_neg_integer()
        }

  defstruct id: 0,
            fragment_id: nil,
            parent_id: nil,
            ordinal: 0,
            role: nil,
            kind: :unknown,
            label: nil,
            line: 0,
            preorder: 0,
            postorder: 0,
            depth: 0
end
