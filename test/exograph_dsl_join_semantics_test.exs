defmodule ExographDSLJoinSemanticsTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.PostgresSupport

  @moduletag :postgres

  setup do
    PostgresSupport.start_repo!()
    prefix = "exograph_dsl_join_semantics_#{System.unique_integer([:positive])}"
    opts = PostgresSupport.opts(prefix)

    on_exit(fn -> Exograph.BackendContract.drop_postgres_prefix(opts) end)

    {:ok, opts: opts}
  end

  test "does not join references from later function fragments", %{opts: opts} do
    path =
      fixture("join_semantics.ex", """
      defmodule Demo.JoinSemantics do
        defp target(user) do
          user
        end

        defp unrelated(user) do
          Repo.transaction(fn -> user end)
        end
      end
      """)

    {:ok, index} = Exograph.index(path, Keyword.merge(opts, min_mass: 4))

    query =
      from(f in Fragment,
        join: d in assoc(f, :definitions),
        join: r in assoc(f, :references),
        where: d.name == "target",
        where: r.qualified_name == "Repo.transaction/1",
        where: matches(f, "defp _ do ... end"),
        select: {f, d, r}
      )

    assert {:ok, []} = Exograph.all(index, query)
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-dsl-join-semantics-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
