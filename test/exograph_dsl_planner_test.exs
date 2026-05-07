defmodule ExographDSLPlannerTest do
  use ExUnit.Case, async: true

  import Exograph.DSL

  alias Exograph.DSL.{Plan, Planner}
  alias Exograph.DSL.Plan.Join

  test "builds a plan with joins and predicates grouped by binding" do
    query =
      from(f in Fragment,
        join: d in assoc(f, :definitions),
        join: e in assoc(f, :calls),
        where: f.kind in [:defp],
        where: d.kind == :defp,
        where: e.callee_qualified_name == "Repo.transaction/1",
        where: matches(f, "defp _ do ... end"),
        select: {f, d, e}
      )

    assert %Plan{} = plan = Planner.plan(query)
    assert plan.source == :fragment
    assert plan.binding == :f
    assert plan.select == {:tuple, [:f, :d, :e]}
    assert plan.structural_predicates == [{:matches, :f, "defp _ do ... end"}]

    assert plan.joins == [
             %Join{
               parent: :f,
               binding: :d,
               assoc: :definitions,
               source: :definition,
               position: 1
             },
             %Join{parent: :f, binding: :e, assoc: :calls, source: :call_edge, position: 2}
           ]

    assert {:in, :f, :kind, [:defp]} in plan.predicates_by_binding.f
    assert {:eq, :d, :kind, :defp} in plan.predicates_by_binding.d
    assert {:eq, :e, :callee_qualified_name, "Repo.transaction/1"} in plan.predicates_by_binding.e
  end
end
