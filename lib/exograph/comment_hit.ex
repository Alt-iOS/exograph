defmodule Exograph.CommentHit do
  @moduledoc "Comment search hit."

  @type t :: %__MODULE__{
          comment: Exograph.Comment.t() | nil,
          fragment: Exograph.Fragment.t() | nil,
          score: number(),
          match: term()
        }

  defstruct comment: nil, fragment: nil, score: 0.0, match: nil

  def new(attrs), do: struct(__MODULE__, attrs)
end
