defmodule Exograph.FeatureCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false
      import PhoenixTest
    end
  end

  setup_all _context do
    Exograph.Test.WebSetup.ensure_started!()
    build_assets!()
    Application.put_env(:phoenix_test, :base_url, Exograph.Test.WebSetup.base_url())
    :ok
  end

  defp build_assets! do
    outdir = Volt.Config.build().outdir |> to_string()
    File.mkdir_p!(outdir)
    vendor_dir = Path.join(outdir, "vendor")

    unless File.regular?(Path.join(vendor_dir, "monaco.js")) do
      File.mkdir_p!(vendor_dir)
      entry = "assets/node_modules/monaco-editor/esm/vs/editor/edcore.main.js"

      if File.regular?(entry) do
        case OXC.bundle(entry,
               cwd: File.cwd!(),
               format: :esm,
               modules: ["assets/node_modules"],
               module_types: Volt.Config.build().module_types,
               define: %{"process.env.NODE_ENV" => ~s("production")}
             ) do
          {:ok, code} -> File.write!(Path.join(vendor_dir, "monaco.js"), code)
          _ -> :ok
        end
      end
    end

    unless File.regular?(Path.join(vendor_dir, "monaco.css")) do
      File.mkdir_p!(vendor_dir)
      src = "assets/node_modules/monaco-editor/min/vs/editor/editor.main.css"
      if File.regular?(src), do: File.cp!(src, Path.join(vendor_dir, "monaco.css"))
    end

    Mix.Task.rerun("volt.build")
  end
end
