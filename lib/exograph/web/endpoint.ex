defmodule Exograph.Web.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :exograph

  @session_options [
    store: :cookie,
    key: "_exograph_web",
    signing_salt: "exograph_web",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :exograph,
    gzip: false,
    only: Exograph.Web.static_paths()
  )

  plug(Volt.DevServer, root: "assets")

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Exograph.Web.Router)
end
