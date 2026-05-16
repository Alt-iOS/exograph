defmodule Exograph.APICase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Exograph.APICase.Helpers
    end
  end

  setup_all _context do
    Exograph.Test.WebSetup.ensure_started!()
    :ok
  end

  defmodule Helpers do
    @base_url "http://localhost:4202"

    def api_get(path) do
      Req.get!("#{@base_url}#{path}", receive_timeout: 30_000)
    end

    def api_post(path, body) do
      Req.post!("#{@base_url}#{path}", json: body, receive_timeout: 30_000)
    end

    def json_body(%{status: status, body: body}) when status in 200..299, do: body
    def json_body(%{body: body}), do: body
  end
end
