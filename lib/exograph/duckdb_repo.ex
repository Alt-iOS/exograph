defmodule Exograph.DuckDBRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :exograph,
    adapter: Ecto.Adapters.QuackDB
end
