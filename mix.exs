defmodule Exograph.MixProject do
  use Mix.Project

  def project do
    [
      app: :exograph,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Exograph.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_ast, "~> 0.10"},
      {:ex_dna, "~> 1.5"},
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
end
