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

  test "rejects duplicate bindings" do
    query = %Exograph.DSL.Query{
      source: :fragment,
      binding: :f,
      joins: [{:assoc, :f, :f, :references}]
    }

    assert_raise ArgumentError, ~r/duplicate Exograph bindings/, fn ->
      Planner.plan(query)
    end
  end

  test "rejects predicates for unbound bindings" do
    query = %Exograph.DSL.Query{
      source: :fragment,
      binding: :f,
      predicates: [{:eq, :missing, :name, "value"}]
    }

    assert_raise ArgumentError, ~r/unknown Exograph binding `missing` in predicate/, fn ->
      Planner.plan(query)
    end
  end

  test "rejects unsupported associations for a source" do
    query = %Exograph.DSL.Query{
      source: :reference,
      binding: :r,
      joins: [{:assoc, :r, :e, :calls}]
    }

    assert_raise ArgumentError, ~r/reference queries do not support joins/, fn ->
      Planner.plan(query)
    end
  end

  test "rejects too many fragment joins" do
    query = %Exograph.DSL.Query{
      source: :fragment,
      binding: :f,
      joins: [
        {:assoc, :f, :d, :definitions},
        {:assoc, :f, :r, :references},
        {:assoc, :f, :e, :calls},
        {:assoc, :f, :other, :references}
      ]
    }

    assert_raise ArgumentError, ~r/fragment queries support at most 3 joins/, fn ->
      Planner.plan(query)
    end
  end

  test "rejects select bindings that are not in the plan" do
    query = %Exograph.DSL.Query{source: :fragment, binding: :f, select: {:tuple, [:f, :missing]}}

    assert_raise ArgumentError, ~r/unknown Exograph binding `missing` in select/, fn ->
      Planner.plan(query)
    end
  end

  test "rejects structural predicates outside fragment queries" do
    query = %Exograph.DSL.Query{
      source: :definition,
      binding: :d,
      predicates: [{:matches, :d, "def _ do ... end"}]
    }

    assert_raise ArgumentError,
                 ~r/structural predicates are only supported for fragment queries/,
                 fn ->
                   Planner.plan(query)
                 end
  end
end
