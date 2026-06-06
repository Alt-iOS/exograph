defmodule Exograph.Web.Server do
  @moduledoc false

  def endpoint_config(port) do
    Application.get_env(:exograph, Exograph.Web.Endpoint, [])
    |> Keyword.merge(
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: port],
      url: [host: "localhost", port: port],
      server: true,
      secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64(),
      live_view: [signing_salt: :crypto.strong_rand_bytes(8) |> Base.encode64()],
      pubsub_server: Exograph.Web.PubSub,
      render_errors: [
        formats: [html: Exograph.Web.ErrorHTML, json: Exograph.Web.ErrorJSON],
        layout: false
      ],
      check_origin: false
    )
  end

  def put_endpoint_config(port) do
    Application.put_env(:exograph, Exograph.Web.Endpoint, endpoint_config(port))
  end

  def start_pubsub_and_endpoint! do
    {:ok, _} =
      Supervisor.start_link([{Phoenix.PubSub, name: Exograph.Web.PubSub}],
        strategy: :one_for_one
      )

    Exograph.Web.Endpoint.start_link()
  end
end
