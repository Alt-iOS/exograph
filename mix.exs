defmodule Exograph.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/elixir-vibe/exograph"

  def project do
    [
      app: :exograph,
      version: @version,
      elixir: "~> 1.19",
      description: "Local CodeQL-style code search for Elixir, backed by Postgres and ExAST.",
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
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
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
        "test --include postgres",
        "cmd mix credo --strict",
        "cmd mix ex_dna",
        "cmd mix reach.check --smells --candidates"
      ]
    ]
  end
end
