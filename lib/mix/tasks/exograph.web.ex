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
      Exograph.index([], repo: repo_module, prefix: prefix, migrate?: false, bm25?: true)

    Application.put_env(:exograph, :web_index, index)
    Application.put_env(:exograph, :web_repo, repo_module)
    Application.put_env(:exograph, :web_prefix, prefix)

    Exograph.Web.Server.put_endpoint_config(port)

    build_assets!()

    if Code.ensure_loaded?(Hammer) do
      Exograph.Web.RateLimiter.start_link([])
    end

    {:ok, _} = Exograph.Web.Server.start_pubsub_and_endpoint!()

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
    Exograph.Web.Monaco.ensure_bundled!()
    Mix.Task.rerun("volt.build")
  end

  defp iex_running?, do: Code.ensure_loaded?(IEx) and IEx.started?()
end
