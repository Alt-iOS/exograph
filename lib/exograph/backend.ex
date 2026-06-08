defmodule Exograph.Backend do
  @moduledoc false

  def duckdb_repo?(repo), do: adapter(repo) == Ecto.Adapters.QuackDB
  def postgres_repo?(repo), do: adapter(repo) == Ecto.Adapters.Postgres

  def adapter(repo), do: repo.__adapter__()
end
