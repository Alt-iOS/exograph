defmodule Exograph.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/elixir-vibe/exograph"

  def project do
    [
      app: :exograph,
      version: @version,
      elixir: "~> 1.19",
      description: "Local CodeQL-style code search for Elixir, backed by Postgres and ExAST.",
      compilers: Mix.compilers() ++ [:phoenix_iconify],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      source_url: @source_url,
      homepage_url: @source_url,
      package: package()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ex_ast, "~> 0.11"},
      {:ex_dna, "~> 1.5"},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.2", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:phoenix, "~> 1.8", optional: true},
      {:phoenix_html, "~> 4.1", optional: true},
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:volt, "~> 0.10", optional: true},
      {:bandit, "~> 1.5", optional: true},
      {:jason, "~> 1.2"},
      {:makeup, "~> 1.0", optional: true},
      {:makeup_elixir, "~> 1.0", optional: true},
      {:hammer, "~> 7.3", optional: true},
      {:dune, "~> 0.3", optional: true},
      {:phoenix_iconify, "~> 0.1", optional: true},
      {:oxc, "~> 0.13.0", override: true}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "CHANGELOG.md",
        "README.md",
        "guides/getting-started.md",
        "guides/querying.md",
        "guides/dsl.md",
        "guides/code-facts.md",
        "guides/call-graph.md",
        "guides/postgres-paradedb.md",
        "guides/package-indexing.md",
        "guides/mix-tasks.md",
        "guides/comparisons.md",
        "guides/architecture.md"
      ]
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "volt.js.check",
        "test --include postgres",
        "cmd mix credo --strict",
        "cmd mix ex_dna",
        "cmd mix reach.check --smells --candidates"
      ]
    ]
  end
end
