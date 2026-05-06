defmodule Exograph.Planner.Plan do
  @moduledoc """
  Full query plan: logical semantics plus selected physical operators.
  """

  alias Exograph.Planner.{LogicalPlan, PhysicalPlan}
  alias Exograph.Query

  @type t :: %__MODULE__{
          query: Query.t(),
          logical: LogicalPlan.t(),
          physical: PhysicalPlan.t(),
          estimated_candidates: non_neg_integer() | :unknown,
          warnings: [atom()]
        }

  defstruct [:query, :logical, :physical, estimated_candidates: :unknown, warnings: []]
end
