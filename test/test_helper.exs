ExUnit.start(exclude: [:feature])

feature_tests? =
  System.get_env("EXOGRAPH_FEATURE_TESTS") ||
    Enum.any?(System.argv(), &String.contains?(&1, "feature"))

if feature_tests? and Code.ensure_loaded?(PhoenixTest.Playwright.Supervisor) do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end

if feature_tests? do
  Exograph.Test.WebSetup.ensure_started!()
end
