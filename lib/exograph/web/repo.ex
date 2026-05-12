defmodule Exograph.Web.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :exograph, adapter: Ecto.Adapters.Postgres
end
