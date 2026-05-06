defmodule Mix.Tasks.Exograph.IndexTest do
  use ExUnit.Case, async: false

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "indexes paths with memory backend" do
    path =
      fixture("sample.ex", """
      defmodule Demo.MixTask do
        def get(id), do: Repo.get!(User, id)
      end
      """)

    Mix.Tasks.Exograph.Index.run(["--min-mass", "4", path])

    assert_receive {:mix_shell, :info, [summary]}
    assert summary =~ "Indexed"
    assert summary =~ "fragments"

    assert_receive {:mix_shell, :info, [backend]}
    assert backend == "Backend: memory"
  end

  test "prints json summary" do
    path =
      fixture("json.ex", """
      defmodule Demo.JsonTask do
        def ok, do: :ok
      end
      """)

    Mix.Tasks.Exograph.Index.run(["--json", "--min-mass", "4", path])

    assert_receive {:mix_shell, :info, [json]}
    assert %{"backend" => "memory", "fragments" => fragments} = Jason.decode!(json)
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
