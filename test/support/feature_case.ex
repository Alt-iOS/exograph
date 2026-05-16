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
    ensure_monaco!()
    Application.put_env(:phoenix_test, :base_url, Exograph.Test.WebSetup.base_url())
    :ok
  end

  defp ensure_monaco! do
    outdir = Volt.Config.build().outdir |> to_string()
    vendor_dir = Path.join(outdir, "vendor")
    monaco_js = Path.join(vendor_dir, "monaco.js")
    monaco_css = Path.join(vendor_dir, "monaco.css")

    unless File.regular?(monaco_js) do
      File.mkdir_p!(vendor_dir)
      entry = "assets/node_modules/monaco-editor/esm/vs/editor/edcore.main.js"

      if File.regular?(entry) do
        case OXC.bundle(entry,
               cwd: File.cwd!(),
               format: :esm,
               modules: ["assets/node_modules"],
               module_types: %{".css" => :empty, ".ttf" => :empty},
               define: %{"process.env.NODE_ENV" => ~s("production")}
             ) do
          {:ok, code} -> File.write!(monaco_js, code)
          _ -> :ok
        end
      end
    end

    unless File.regular?(monaco_css) do
      File.mkdir_p!(vendor_dir)
      src = "assets/node_modules/monaco-editor/min/vs/editor/editor.main.css"
      if File.regular?(src), do: File.cp!(src, Path.join(vendor_dir, "monaco.css"))
    end
  end
end
