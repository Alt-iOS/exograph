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
    start_web!()
    Application.put_env(:phoenix_test, :base_url, "http://localhost:4202")
    :ok
  end

  defp start_web! do
    if Process.whereis(Exograph.Web.Endpoint) do
      :already_started
    else
      prefix = "exograph_test"

      database_url =
        System.get_env("EXOGRAPH_DATABASE_URL", "postgres://dannote@localhost:5432/postgres")

      repo_opts = [url: database_url, pool_size: 5, log: false, timeout: 120_000]

      case Exograph.Web.Repo.start_link(repo_opts) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      {:ok, index} =
        Exograph.index([],
          repo: Exograph.Web.Repo,
          prefix: prefix,
          migrate?: false,
          bm25?: false
        )

      Application.put_env(:exograph, :web_index, index)
      Application.put_env(:exograph, :web_repo, Exograph.Web.Repo)
      Application.put_env(:exograph, :web_prefix, prefix)

      endpoint_config = [
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: 4202],
        url: [host: "localhost", port: 4202],
        server: true,
        secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64(),
        live_view: [signing_salt: :crypto.strong_rand_bytes(8) |> Base.encode64()],
        pubsub_server: Exograph.Web.PubSub,
        render_errors: [
          formats: [html: Exograph.Web.ErrorHTML, json: Exograph.Web.ErrorJSON],
          layout: false
        ],
        check_origin: false
      ]

      Application.put_env(:exograph, Exograph.Web.Endpoint, endpoint_config)

      unless Process.whereis(Exograph.Web.PubSub) do
        {:ok, _} =
          Supervisor.start_link([{Phoenix.PubSub, name: Exograph.Web.PubSub}],
            strategy: :one_for_one
          )
      end

      Mix.Task.rerun("volt.build")
      ensure_monaco!()

      if Code.ensure_loaded?(Exograph.Web.RateLimiter) do
        case Exograph.Web.RateLimiter.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      end

      {:ok, _} = Exograph.Web.Endpoint.start_link()
      :started
    end
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
      if File.regular?(src), do: File.cp!(src, monaco_css)
    end
  end
end
