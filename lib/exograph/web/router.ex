defmodule Exograph.Web.Router do
  @moduledoc false

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Exograph.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", Exograph.Web do
    pipe_through(:browser)

    live("/", QueryLive, :index)
  end
end
