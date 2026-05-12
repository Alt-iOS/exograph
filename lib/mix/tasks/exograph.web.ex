defmodule Mix.Tasks.Exograph.Web do
  @moduledoc """
  Starts a standalone web interface for exploring an Exograph index.

      mix exograph.web --repo MyApp.Repo --prefix exograph

  Options:

    * `--repo` — Ecto repo module (required)
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

    repo_module = parse_repo(opts[:repo]) || Exograph.Web.Repo
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

    Application.put_env(:exograph, Exograph.Web.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: port],
      url: [host: "localhost", port: port],
      server: true,
      secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64(),
      live_view: [signing_salt: :crypto.strong_rand_bytes(8) |> Base.encode64()],
      pubsub_server: Exograph.Web.PubSub,
      render_errors: [formats: [html: Exograph.Web.ErrorHTML], layout: false],
      code_reloader: true,
      check_origin: false,
      watchers: []
    )

    Application.put_env(:volt, :server, prefix: "/assets", watch_dirs: ["lib/", "assets/"])

    Application.put_env(:volt, :build,
      entry: "assets/js/app.ts",
      outdir: "priv/static/assets",
      root: "assets",
      sources: ["**/*.{js,ts}"],
      target: :es2020,
      minify: false,
      hash: false,
      resolve_dirs: ["assets/node_modules", "deps"]
    )

    Application.put_env(:volt, :tailwind,
      css: "assets/css/app.css",
      sources: [
        %{base: "lib/", pattern: "**/*.{ex,heex}"},
        %{base: "assets/", pattern: "**/*.{js,ts}"}
      ]
    )

    {:ok, _} =
      Supervisor.start_link([{Phoenix.PubSub, name: Exograph.Web.PubSub}], strategy: :one_for_one)

    {:ok, _} = Exograph.Web.Endpoint.start_link()

    Mix.shell().info([
      "Exograph web interface running at ",
      IO.ANSI.cyan(),
      "http://localhost:#{port}",
      IO.ANSI.reset()
    ])

    unless iex_running?() do
      Process.sleep(:infinity)
    end
  end

  defp parse_repo(nil), do: nil

  defp parse_repo(repo_string) do
    Module.concat([repo_string])
  end

  defp start_repo(repo_module, opts) do
    case Process.whereis(repo_module) do
      nil ->
        if Code.ensure_loaded?(repo_module) do
          repo_module.start_link(opts)
        else
          start_dynamic_repo(opts)
        end

      pid ->
        {:ok, pid}
    end
  end

  defp start_dynamic_repo(opts) do
    Application.put_env(:exograph, Exograph.Web.Repo, opts)
    Exograph.Web.Repo.start_link(opts)
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
