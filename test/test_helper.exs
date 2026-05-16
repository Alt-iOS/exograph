ExUnit.start(exclude: [:feature])

if Code.ensure_loaded?(PhoenixTest.Playwright.Supervisor) do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end
