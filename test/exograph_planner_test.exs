defmodule ExographPlannerTest do
  use ExUnit.Case, async: false

  import ExAST.Query

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_planner_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "plans selective queries as term index scans plus exact verification", %{opts: opts} do
    path =
      fixture("planner.ex", """
      defmodule Demo.Planner do
        def safe do
          Repo.transaction(fn -> :ok end)
        end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from("def _ do ... end")
      |> where(contains("Repo.transaction(_)"))

    plan = Exograph.plan(index, query)
    explanation = Exograph.explain(plan)

    assert match?({:term_index_scan, _}, explanation.physical.scan)
    assert :ex_ast_verify in explanation.physical.filters
    assert "call.remote:Repo.transaction/1" in explanation.logical.required_terms
  end

  test "plans broad queries as fragment sequential scans", %{opts: opts} do
    path =
      fixture("broad.ex", """
      defmodule Demo.Broad do
        def ok, do: :ok
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))
    plan = Exograph.plan(index, "_")

    assert Exograph.explain(plan).physical.scan == :fragment_seq_scan
  end

  test "negative predicates are verifier-only and do not hard-exclude candidates", %{opts: opts} do
    path =
      fixture("negative.ex", """
      defmodule Demo.Negative do
        def safe do
          Repo.transaction(fn -> :ok end)
        end

        def noisy do
          Repo.transaction(fn -> IO.inspect(:debug) end)
        end
      end
      """)

    query =
      from("def _ do ... end")
      |> where(contains("Repo.transaction(_)"))
      |> where(not contains("IO.inspect(_)"))

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))
    explanation = index |> Exograph.plan(query) |> Exograph.explain()

    assert "call.remote:Repo.transaction/1" in explanation.logical.required_terms
    assert "call.remote:IO.inspect/1" in explanation.logical.verifier_only_negative_terms
    assert match?({:term_index_scan, _}, explanation.physical.scan)

    {:ok, results} = Exograph.search(index, query)

    assert Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:safe, _, _} | _]}, node)
           end)

    refute Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:noisy, _, _} | _]}, node)
           end)
  end

  test "verification limit is applied after exact verification", %{opts: opts} do
    path =
      fixture("post_verify_limit.ex", """
      defmodule Demo.PostVerifyLimit do
        def unrelated_one, do: :ok
        def unrelated_two, do: :ok
        def target, do: Target.hit(:ok)
      end
      """)

    query =
      from("def _ do ... end")
      |> where(contains("Target.hit(_)"))

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))
    {:ok, results} = Exograph.search(index, query, limit: 1)

    assert [%{match: %{node: {:def, _, [{:target, _, _} | _]}}}] = results
  end

  test "any predicates do not become unsafe intersected candidate terms", %{opts: opts} do
    path =
      fixture("any.ex", """
      defmodule Demo.AnyPredicate do
        def left do
          Foo.left(:ok)
        end

        def right do
          Bar.right(:ok)
        end
      end
      """)

    query =
      from("def _ do ... end")
      |> where(any([contains("Foo.left(_)"), contains("Bar.right(_)")]))

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))
    explanation = index |> Exograph.plan(query) |> Exograph.explain()

    refute "call.remote:Foo.left/1" in explanation.logical.required_terms
    refute "call.remote:Bar.right/1" in explanation.logical.required_terms
    assert match?({:union_term_index_scan, _}, explanation.physical.scan)
    assert Enum.any?(explanation.logical.candidate_groups, &("call.remote:Foo.left/1" in &1))
    assert Enum.any?(explanation.logical.candidate_groups, &("call.remote:Bar.right/1" in &1))

    {:ok, results} = Exograph.search(index, query)
    names = Enum.map(results, fn %{match: %{node: {:def, _, [head | _]}}} -> elem(head, 0) end)

    assert :left in names
    assert :right in names
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-planner-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
