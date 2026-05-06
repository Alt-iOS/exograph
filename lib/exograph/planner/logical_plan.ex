defmodule Exograph.Planner.LogicalPlan do
  @moduledoc """
  Backend-independent query semantics.
  """

  alias Exograph.Query

  @type t :: %__MODULE__{
          source: term(),
          verifier: Query.verifier(),
          required_terms: MapSet.t(String.t()),
          optional_terms: MapSet.t(String.t()),
          verifier_only_negative_terms: MapSet.t(String.t()),
          candidate_groups: [MapSet.t(String.t())]
        }

  defstruct source: nil,
            verifier: nil,
            required_terms: MapSet.new(),
            optional_terms: MapSet.new(),
            verifier_only_negative_terms: MapSet.new(),
            candidate_groups: []

  @spec from_query(Query.t()) :: t()
  def from_query(%Query{} = query) do
    %__MODULE__{
      source: query.source,
      verifier: query.verifier,
      required_terms: query.required_terms,
      optional_terms: query.optional_terms,
      verifier_only_negative_terms: query.negative_terms,
      candidate_groups: query.candidate_groups
    }
  end
end
