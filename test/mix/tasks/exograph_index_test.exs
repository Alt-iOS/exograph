defmodule Mix.Tasks.Exograph.IndexTest do
  use ExUnit.Case, async: false

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    Mix.shell(Mix.Shell.Process)
    prefix = "exograph_mix_task_#{System.unique_integer([:positive])}"
    opts = [repo: Exograph.TestRepo, prefix: prefix]

    on_exit(fn ->
      Exograph.BackendContract.drop_postgres_prefix(opts)
      Mix.shell(Mix.Shell.IO)
    end)

    {:ok, prefix: prefix}
  end

  test "indexes paths with postgres backend", %{prefix: prefix} do
    path =
      fixture("sample.ex", """
      defmodule Demo.MixTask do
        def get(id), do: Repo.get!(User, id)
      end
      """)

    Mix.Tasks.Exograph.Index.run([
      "--repo",
      "Exograph.TestRepo",
      "--prefix",
      prefix,
      "--migrate",
      "--no-bm25",
      "--min-mass",
      "4",
      path
    ])

    assert_receive {:mix_shell, :info, [summary]}
    assert summary =~ "Indexed"
    assert summary =~ "fragments"

    assert_receive {:mix_shell, :info, [backend]}
    assert backend == "Backend: postgres"
  end

  test "prints json summary", %{prefix: prefix} do
    path =
      fixture("json.ex", """
      defmodule Demo.JsonTask do
        def ok, do: :ok
      end
      """)

    Mix.Tasks.Exograph.Index.run([
      "--json",
      "--repo",
      "Exograph.TestRepo",
      "--prefix",
      prefix,
      "--migrate",
      "--no-bm25",
      "--min-mass",
      "4",
      path
    ])

    assert_receive {:mix_shell, :info, [json]}
    assert %{"backend" => "postgres", "fragments" => fragments} = Jason.decode!(json)
    assert fragments > 0
  end

  test "rejects unknown backend" do
    assert_raise Mix.Error, ~r/Unknown backend/, fn ->
      Mix.Tasks.Exograph.Index.run(["--backend", "wat"])
    end
  end

  defp fixture(name, source) do
    dir = Path.join(System.tmp_dir!(), "exograph-mix-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
