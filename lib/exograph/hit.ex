defmodule Exograph.Hit do
  @moduledoc """
  Candidate or verified search hit.
  """

  alias Exograph.Fragment

  @type t :: %__MODULE__{
          fragment: Fragment.t() | nil,
          fragment_id: Fragment.id() | nil,
          score: number(),
          matched_terms: [String.t()],
          match: term()
        }

  defstruct fragment: nil,
            fragment_id: nil,
            score: 0.0,
            matched_terms: [],
            match: nil

  def new(attrs), do: struct(__MODULE__, attrs)

  def with_match(%__MODULE__{} = hit, match), do: %{hit | match: match}
end
