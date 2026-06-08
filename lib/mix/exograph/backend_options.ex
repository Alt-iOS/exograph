defmodule Mix.Exograph.BackendOptions do
  @moduledoc false

  def backend_opts("postgres", opts) do
    [
      repo: repo!(opts),
      prefix: Keyword.get(opts, :prefix, "exograph"),
      migrate?: Keyword.get(opts, :migrate, false),
      bm25?: !Keyword.get(opts, :no_bm25, false)
    ]
  end

  def backend_opts("duckdb", opts) do
    [
      repo: duckdb_repo!(opts),
      prefix: Keyword.get(opts, :prefix, "exograph"),
      migrate?: Keyword.get(opts, :migrate, false),
      bm25?: !Keyword.get(opts, :no_bm25, false),
      duckdb_threads: Keyword.get(opts, :duckdb_threads)
    ]
  end

  def backend_opts(other, _opts) do
    Mix.raise("Unknown backend #{inspect(other)}. Expected: postgres or duckdb")
  end

  defp duckdb_repo!(opts) do
    case Keyword.get(opts, :repo) do
      nil -> start_default_duckdb_repo!(opts)
      repo -> module!(repo)
    end
  end

  defp start_default_duckdb_repo!(opts) do
    Application.ensure_all_started(:quackdb)

    Application.put_env(:exograph, Exograph.DuckDBRepo,
      uri:
        Keyword.get(opts, :quackdb_uri) || System.get_env("QUACKDB_URI") ||
          System.get_env("QUACKDB_TEST_URI") || Mix.raise("Missing --quackdb-uri"),
      token:
        Keyword.get(opts, :quackdb_token) || System.get_env("QUACKDB_TOKEN") ||
          System.get_env("QUACKDB_TEST_TOKEN", ""),
      pool_size: 5,
      telemetry_prefix: [:quackdb],
      log: false,
      timeout: 120_000
    )

    case Process.whereis(Exograph.DuckDBRepo) do
      nil -> {:ok, _pid} = Exograph.DuckDBRepo.start_link()
      _pid -> :ok
    end

    Exograph.DuckDBRepo
  end

  defp repo!(opts) do
    opts
    |> Keyword.fetch!(:repo)
    |> module!()
  end

  defp module!(name) do
    name
    |> String.split(".")
    |> Module.concat()
  end
end
