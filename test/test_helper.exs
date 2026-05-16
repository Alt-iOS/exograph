ExUnit.start(exclude: [:feature])

if Code.ensure_loaded?(PhoenixTest.Playwright.Supervisor) do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end

if System.get_env("EXOGRAPH_FEATURE_TESTS") ||
     Enum.any?(System.argv(), &String.contains?(&1, "feature")) do
  Exograph.Test.WebSetup.ensure_started!()
end
