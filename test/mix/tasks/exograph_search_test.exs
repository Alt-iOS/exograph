defmodule Mix.Tasks.Exograph.SearchTest do
  use ExUnit.Case, async: false

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    Mix.shell(Mix.Shell.Process)
    prefix = "exograph_search_task_#{System.unique_integer([:positive])}"
    opts = [repo: Exograph.TestRepo, prefix: prefix]

    on_exit(fn ->
      Exograph.BackendContract.drop_postgres_prefix(opts)
      Mix.shell(Mix.Shell.IO)
    end)

    {:ok, prefix: prefix}
  end

  test "searches AST patterns", %{prefix: prefix} do
    path =
      fixture("sample.ex", """
      defmodule Demo.SearchTask do
        def get(id), do: Repo.get!(User, id)
      end
      """)

    Mix.Tasks.Exograph.Search.run(
      base_args(prefix) ++ ["Repo.get!(_, _)", "--min-mass", "4", path]
    )

    assert_receive {:mix_shell, :info, [summary]}
    assert summary =~ "result(s)"
    assert_receive {:mix_shell, :info, [result]}
    assert result =~ path
  end

  test "searches selector contains and not contains", %{prefix: prefix} do
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

    Mix.Tasks.Exograph.Search.run(
      base_args(prefix) ++
        [
          "def _ do ... end",
          "--contains",
          "Repo.transaction(_)",
          "--not-contains",
          "IO.inspect(_)",
          "--min-mass",
          "4",
          path
        ]
    )

    assert_receive {:mix_shell, :info, [summary]}
    assert summary =~ "result(s)"
    assert_receive {:mix_shell, :info, [result]}
    assert result =~ "safe"
    refute result =~ "noisy"
  end

  test "searches literal text", %{prefix: prefix} do
    path =
      fixture("text.ex", """
      defmodule Demo.TextTask do
        def route, do: ~p"/users/:id"
      end
      """)

    Mix.Tasks.Exograph.Search.run(
      base_args(prefix) ++ ["/users/:id", "--text", "--min-mass", "4", path]
    )

    assert_receive {:mix_shell, :info, [summary]}
    assert summary =~ "result(s)"
    assert_receive {:mix_shell, :info, [result]}
    assert result =~ path
  end

  defp base_args(prefix) do
    ["--repo", "Exograph.TestRepo", "--prefix", prefix, "--migrate", "--no-bm25"]
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
