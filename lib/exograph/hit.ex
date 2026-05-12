defmodule Exograph.Hit do
  @moduledoc """
  Candidate or verified search hit.

  ## Hit type hierarchy

  Exograph returns typed hit structs depending on the search function:

  - `Exograph.Hit` — structural pattern/selector match from `Exograph.search/3`
  - `Exograph.TextHit` — source text match from `search_text/3`
  - `Exograph.CommentHit` — comment match from `search_comments/3`
  - `Exograph.DefinitionHit` — definition name match from `search_definitions/3`
  - `Exograph.ReferenceHit` — reference name match from `search_references/3`
  - `Exograph.CallEdgeHit` — call graph edge from `search_callers/3` / `search_callees/3`

  All hit types expose `:fragment`, `:score`, and `:match` fields.
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
