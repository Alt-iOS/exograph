defmodule Mix.Tasks.Exograph.Web do
  @moduledoc """
  Starts a standalone web interface for exploring an Exograph index.

      mix exograph.web --prefix exograph

  Options:

    * `--repo` — Ecto repo module (optional, uses built-in repo if omitted)
    * `--prefix` — table prefix (default: `exograph`)
    * `--port` — HTTP port (default: `4200`)
    * `--database-url` — Postgres URL (or set `EXOGRAPH_DATABASE_URL`)

  """
  use Mix.Task

  @impl true
  def run(args) do
    unless Code.ensure_loaded?(Phoenix) do
      Mix.raise(
        "mix exograph.web requires phoenix, phoenix_live_view, volt, and bandit as dependencies"
      )
    end

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [repo: :string, prefix: :string, port: :integer, database_url: :string]
      )

    repo_module = if opts[:repo], do: Module.concat([opts[:repo]]), else: Exograph.Web.Repo
    prefix = opts[:prefix] || "exograph"
    port = opts[:port] || 4200
    database_url = opts[:database_url] || System.get_env("EXOGRAPH_DATABASE_URL")

    Application.ensure_all_started(:exograph)
    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:phoenix_live_view)

    repo_opts =
      if database_url do
        [url: database_url, pool_size: 5, ssl: false, log: false, timeout: 120_000]
      else
        Application.get_env(Mix.Project.config()[:app], repo_module, [])
        |> Keyword.merge(pool_size: 5, log: false, timeout: 120_000)
      end

    {:ok, _pid} = start_repo(repo_module, repo_opts)

    {:ok, index} =
      Exograph.index([], repo: repo_module, prefix: prefix, migrate?: false, bm25?: false)

    Application.put_env(:exograph, :web_index, index)
    Application.put_env(:exograph, :web_repo, repo_module)
    Application.put_env(:exograph, :web_prefix, prefix)

    endpoint_config =
      Application.get_env(:exograph, Exograph.Web.Endpoint, [])
      |> Keyword.merge(
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: port],
        url: [host: "localhost", port: port],
        server: true,
        secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64(),
        live_view: [signing_salt: :crypto.strong_rand_bytes(8) |> Base.encode64()],
        pubsub_server: Exograph.Web.PubSub,
        render_errors: [formats: [html: Exograph.Web.ErrorHTML], layout: false],
        check_origin: false
      )

    Application.put_env(:exograph, Exograph.Web.Endpoint, endpoint_config)

    build_assets!()

    {:ok, _} =
      Supervisor.start_link([{Phoenix.PubSub, name: Exograph.Web.PubSub}],
        strategy: :one_for_one
      )

    {:ok, _} = Exograph.Web.Endpoint.start_link()

    Mix.shell().info([
      "Exograph web running at ",
      IO.ANSI.cyan(),
      "http://localhost:#{port}",
      IO.ANSI.reset()
    ])

    unless iex_running?(), do: Process.sleep(:infinity)
  end

  defp start_repo(repo_module, opts) do
    case Process.whereis(repo_module) do
      nil ->
        if Code.ensure_loaded?(repo_module) do
          repo_module.start_link(opts)
        else
          Application.put_env(:exograph, Exograph.Web.Repo, opts)
          Exograph.Web.Repo.start_link(opts)
        end

      pid ->
        {:ok, pid}
    end
  end

  defp build_assets! do
    outdir = Volt.Config.build().outdir |> to_string()
    File.mkdir_p!(outdir)

    build_tailwind!(outdir)
    build_monaco!(outdir)
    build_js!()
  end

  defp build_js! do
    config = Volt.Config.build()

    case Volt.Builder.build(
           entry: config.entry,
           outdir: to_string(config.outdir),
           target: config.target,
           hash: false,
           sourcemap: false,
           format: :esm,
           external: [],
           resolve_dirs: config.resolve_dirs,
           aliases: config.aliases,
           plugins: config.plugins,
           minify: false
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.shell().error("JS build failed: #{inspect(reason)}")
    end
  end

  defp build_tailwind!(outdir) do
    tw = Volt.Config.tailwind()
    css_path = Keyword.get(tw, :css)

    if css_path && File.regular?(css_path) do
      case Volt.Tailwind.build(
             css: File.read!(css_path),
             css_base: Path.dirname(css_path),
             sources: Keyword.get(tw, :sources, [])
           ) do
        {:ok, css} -> File.write!(Path.join(outdir, "app.css"), css)
        {:error, reason} -> Mix.shell().error("Tailwind build failed: #{inspect(reason)}")
      end
    end
  end

  defp build_monaco!(outdir) do
    vendor_dir = Path.join(outdir, "vendor")
    monaco_path = Path.join(vendor_dir, "monaco.js")
    monaco_css = Path.join(vendor_dir, "monaco.css")

    unless File.regular?(monaco_css) do
      File.mkdir_p!(vendor_dir)
      src_css = "assets/node_modules/monaco-editor/min/vs/editor/editor.main.css"
      if File.regular?(src_css), do: File.cp!(src_css, monaco_css)
    end

    if File.regular?(monaco_path) do
      :ok
    else
      Mix.shell().info("Pre-bundling Monaco Editor...")
      File.mkdir_p!(vendor_dir)

      entry = "assets/node_modules/monaco-editor/esm/vs/editor/edcore.main.js"

      case OXC.bundle(entry,
             cwd: File.cwd!(),
             format: :esm,
             modules: ["assets/node_modules"],
             module_types: %{".css" => :empty, ".ttf" => :empty},
             define: %{"process.env.NODE_ENV" => ~s("production")}
           ) do
        {:ok, code} when is_binary(code) ->
          File.write!(monaco_path, code)
          Mix.shell().info("Monaco bundled: #{div(byte_size(code), 1024)}KB")

        {:error, errors} ->
          Mix.shell().error("Monaco bundle failed: #{inspect(errors)}")
      end
    end
  end

  defp iex_running?, do: Code.ensure_loaded?(IEx) and IEx.started?()
end
