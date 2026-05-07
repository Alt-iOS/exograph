defmodule Mix.Exograph.PostgresOptions do
  @moduledoc false

  def backend_opts("postgres", opts) do
    [
      repo: repo!(opts),
      prefix: Keyword.get(opts, :prefix, "exograph"),
      migrate?: Keyword.get(opts, :migrate, false),
      bm25?: !Keyword.get(opts, :no_bm25, false)
    ]
  end

  def backend_opts(other, _opts) do
    Mix.raise("Unknown backend #{inspect(other)}. Expected: postgres")
  end

  defp repo!(opts) do
    opts
    |> Keyword.fetch!(:repo)
    |> String.split(".")
    |> Module.concat()
  end
end
