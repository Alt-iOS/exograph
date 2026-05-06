defmodule ExographPlannerTest do
  use ExUnit.Case, async: false

  import ExAST.Query

  test "plans selective queries as term index scans plus exact verification" do
    path =
      fixture("planner.ex", """
      defmodule Demo.Planner do
        def safe do
          Repo.transaction(fn -> :ok end)
        end
      end
      """)

    {:ok, index} = Exograph.index(path, min_mass: 4)

    query =
      from("def _ do ... end")
      |> where(contains("Repo.transaction(_)"))

    plan = Exograph.plan(index, query)
    explanation = Exograph.explain(plan)

    assert match?({:term_index_scan, _}, explanation.physical.scan)
    assert :ex_ast_verify in explanation.physical.filters
    assert "call.remote:Repo.transaction/1" in explanation.logical.required_terms
  end

  test "plans broad queries as fragment sequential scans" do
    path =
      fixture("broad.ex", """
      defmodule Demo.Broad do
        def ok, do: :ok
      end
      """)

    {:ok, index} = Exograph.index(path, min_mass: 4)
    plan = Exograph.plan(index, "_")

    assert Exograph.explain(plan).physical.scan == :fragment_seq_scan
  end

  test "negative predicates are verifier-only and do not hard-exclude candidates" do
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

    {:ok, index} = Exograph.index(path, min_mass: 4)
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

  test "verification limit is applied after exact verification" do
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

    {:ok, index} = Exograph.index(path, min_mass: 4)
    {:ok, results} = Exograph.search(index, query, limit: 1)

    assert [%{match: %{node: {:def, _, [{:target, _, _} | _]}}}] = results
  end

  test "any predicates do not become unsafe intersected candidate terms" do
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

    {:ok, index} = Exograph.index(path, min_mass: 4)
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

  test "Tantivy and memory backends preserve any predicate semantics" do
    path =
      fixture("tantivy_any.ex", """
      defmodule Demo.TantivyAny do
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

    {:ok, memory_index} = Exograph.index(path, min_mass: 4)

    tantivy_path =
      Path.join(
        System.tmp_dir!(),
        "exograph-planner-any-tantivy-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(tantivy_path)

    {:ok, tantivy_index} =
      Exograph.index(path,
        min_mass: 4,
        backend: Exograph.InvertedIndex.TantivyEx,
        backend_opts: [path: tantivy_path]
      )

    assert {:ok, memory_results} = Exograph.search(memory_index, query)
    assert {:ok, tantivy_results} = Exograph.search(tantivy_index, query)

    assert result_locations(memory_results) == result_locations(tantivy_results)
  end

  test "Tantivy and memory backends preserve verified query semantics" do
    path =
      fixture("equivalence.ex", """
      defmodule Demo.Equivalence do
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

    {:ok, memory_index} = Exograph.index(path, min_mass: 4)

    tantivy_path =
      Path.join(
        System.tmp_dir!(),
        "exograph-planner-tantivy-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(tantivy_path)

    {:ok, tantivy_index} =
      Exograph.index(path,
        min_mass: 4,
        backend: Exograph.InvertedIndex.TantivyEx,
        backend_opts: [path: tantivy_path]
      )

    assert {:ok, memory_results} = Exograph.search(memory_index, query)
    assert {:ok, tantivy_results} = Exograph.search(tantivy_index, query)

    assert result_locations(memory_results) == result_locations(tantivy_results)
  end

  defp result_locations(results) do
    results
    |> Enum.map(fn result ->
      {result.fragment.file, node_line(result.match.node), Macro.to_string(result.match.node)}
    end)
    |> Enum.sort()
  end

  defp node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp node_line(_node), do: 0

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
