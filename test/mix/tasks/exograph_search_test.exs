defmodule Mix.Tasks.Exograph.SearchTest do
  use ExUnit.Case, async: false

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "searches AST patterns" do
    path =
      fixture("sample.ex", """
      defmodule Demo.SearchTask do
        def get(id), do: Repo.get!(User, id)
      end
      """)

    Mix.Tasks.Exograph.Search.run(["Repo.get!(_, _)", "--min-mass", "4", path])

    assert_receive {:mix_shell, :info, [summary]}
    assert summary =~ "result(s)"
    assert_receive {:mix_shell, :info, [result]}
    assert result =~ path
  end

  test "searches selector contains and not contains" do
    path =
      fixture("selector.ex", """
      defmodule Demo.SearchSelectorTask do
        def safe do
          Repo.transaction(fn -> :ok end)
        end

        def noisy do
          Repo.transaction(fn -> IO.inspect(:debug) end)
        end
      end
      """)

    Mix.Tasks.Exograph.Search.run([
      "def _ do ... end",
      "--contains",
      "Repo.transaction(_)",
      "--not-contains",
      "IO.inspect(_)",
      "--min-mass",
      "4",
      path
    ])

    assert_receive {:mix_shell, :info, [summary]}
    assert summary =~ "result(s)"
    assert_receive {:mix_shell, :info, [result]}
    assert result =~ "safe"
    refute result =~ "noisy"
  end

  test "prints explain plan" do
    path =
      fixture("explain.ex", """
      defmodule Demo.ExplainTask do
        def get(id), do: Repo.get!(User, id)
      end
      """)

    Mix.Tasks.Exograph.Search.run(["Repo.get!(_, _)", "--explain", "--min-mass", "4", path])

    assert_receive {:mix_shell, :info, [plan]}
    assert plan =~ "term_index_scan"
  end

  test "searches literal text" do
    path =
      fixture("text.ex", """
      defmodule Demo.TextTask do
        def route, do: ~p"/users/:id"
      end
      """)

    Mix.Tasks.Exograph.Search.run(["/users/:id", "--text", "--min-mass", "4", path])

    assert_receive {:mix_shell, :info, [summary]}
    assert summary =~ "result(s)"
    assert_receive {:mix_shell, :info, [result]}
    assert result =~ path
  end

  defp fixture(name, source) do
    dir =
      Path.join(System.tmp_dir!(), "exograph-search-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
