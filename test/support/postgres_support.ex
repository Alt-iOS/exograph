defmodule Exograph.PostgresSupport do
  @moduledoc false

  def url do
    System.get_env("EXOGRAPH_DATABASE_URL") || "postgres://dannote@localhost:5432/postgres"
  end

  def start_repo! do
    case Process.whereis(Exograph.TestRepo) do
      pid when is_pid(pid) ->
        pid

      nil ->
        {:ok, pid} =
          Exograph.TestRepo.start_link(
            url: url(),
            pool_size: 2,
            ssl: false,
            stacktrace: true,
            show_sensitive_data_on_connection_error: true,
            log: false
          )

        Process.unlink(pid)
        pid
    end
  rescue
    error -> raise "Postgres is required for Exograph tests: #{inspect(error)}"
  end

  def opts(prefix, extra \\ []) do
    Keyword.merge(
      [
        backend: :postgres,
        repo: Exograph.TestRepo,
        prefix: prefix,
        migrate?: true,
        bm25?: false,
        package_version: [ecosystem: :hex, name: prefix, version: "1.0.0"]
      ],
      extra
    )
  end
end
