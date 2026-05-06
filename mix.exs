defmodule Exograph.MixProject do
  use Mix.Project

  def project do
    [
      app: :exograph,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Exograph.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ex_ast, "~> 0.11"},
      {:ex_dna, "~> 1.5"},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.2", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22"},
      {:tantivy_ex, "~> 0.4.1", optional: true},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "cmd mix credo --strict",
        "cmd mix ex_dna",
        "cmd mix reach.check --smells --candidates"
      ]
    ]
  end
end
