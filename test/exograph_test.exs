defmodule ExographTest do
  use ExUnit.Case, async: true

  import ExAST.Query

  test "indexes Elixir fragments and verifies pattern queries" do
    path =
      fixture("sample.ex", """
      defmodule Demo.Accounts do
        def get_user(id) do
          Repo.get!(User, id)
        end

        def ok do
          :ok
        end
      end
      """)

    {:ok, index} = Exograph.index(path, min_mass: 4)
    {:ok, results} = Exograph.search(index, "Repo.get!(_, _)")

    assert [%{fragment: fragment}] = results
    assert fragment.file == path
  end

  test "compiles selector predicates into candidate terms and verifies exact match" do
    path =
      fixture("selector.ex", """
      defmodule Demo.Workers do
        def safe do
          Repo.transaction(fn -> :ok end)
        end

        def noisy do
          Repo.transaction(fn -> IO.inspect(:debug) end)
        end
      end
      """)

    selector =
      from("def _ do ... end")
      |> where(contains("Repo.transaction(_)"))
      |> where(not contains("IO.inspect(_)"))

    {:ok, index} = Exograph.index(path, min_mass: 4)
    {:ok, results} = Exograph.search(index, selector)

    assert Enum.any?(results, fn %{match: %{node: node}} ->
             match?({:def, _, [{:safe, _, _} | _]}, node)
           end)
  end

  test "query compiler supports selector alternatives and sibling predicates" do
    selector =
      from(["def _ do ... end", "defp _ do ... end"])
      |> where(follows("@doc _"))
      |> where(first())

    query = Exograph.compile(selector)

    assert "node:def" in query.optional_terms
    assert "node:defp" in query.optional_terms
    assert "attribute:doc" in query.required_terms
  end

  test "query compiler emits structural terms" do
    query = Exograph.compile("Repo.get!(User, id)")

    assert "call.remote:Repo.get!/2" in query.required_terms
    assert "alias:User" in query.required_terms
    assert Kernel.not("atom:id" in query.required_terms)
  end

  defp fixture(name, source) do
    dir = Path.join(System.tmp_dir!(), "exograph-tests-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
