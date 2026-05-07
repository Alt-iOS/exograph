defmodule Exograph.Backend do
  @moduledoc """
  High-level backend profile behaviour.

  Exograph's production backend is Postgres. Backend profiles wire the lower-level
  storage behaviours used by an index, but built-in non-Postgres profiles are no
  longer part of the public API.
  """

  alias Exograph.Backend.Postgres
  alias Exograph.FragmentStore.Postgres, as: PostgresFragmentStore
  alias Exograph.TreeStore.Postgres, as: PostgresTreeStore

  @type config :: [
          inverted: module(),
          inverted_opts: keyword(),
          fragment_store: module(),
          fragment_store_opts: keyword(),
          tree_store: module(),
          tree_store_opts: keyword()
        ]

  @callback config(keyword()) :: config()

  @spec config(keyword()) :: config()
  def config(opts) do
    profile_config(opts)
    |> override(opts, :inverted_opts, :backend_opts)
    |> override(opts, :fragment_store, :fragment_store)
    |> override(opts, :fragment_store_opts, :fragment_store_opts)
    |> override(opts, :tree_store, :tree_store)
    |> override(opts, :tree_store_opts, :tree_store_opts)
  end

  defp profile_config(opts) do
    case Keyword.get(opts, :backend) do
      nil ->
        Postgres.config(opts)

      :postgres ->
        Postgres.config(opts)

      backend when backend in [:memory, :tantivy] ->
        raise ArgumentError, "unsupported backend #{inspect(backend)}; use :postgres"

      module when is_atom(module) ->
        module_profile_config(module, opts)
    end
  end

  defp module_profile_config(module, opts) do
    Code.ensure_loaded(module)

    if function_exported?(module, :config, 1) do
      module.config(opts)
    else
      [
        inverted: module,
        inverted_opts: shared_store_opts(opts),
        fragment_store: Keyword.get(opts, :fragment_store, PostgresFragmentStore),
        fragment_store_opts: shared_store_opts(opts),
        tree_store: Keyword.get(opts, :tree_store, PostgresTreeStore),
        tree_store_opts: shared_store_opts(opts)
      ]
    end
  end

  defp override(config, opts, config_key, option_key) do
    case Keyword.fetch(opts, option_key) do
      {:ok, value} -> Keyword.put(config, config_key, merge_opts(config_key, config, value))
      :error -> config
    end
  end

  defp merge_opts(config_key, config, value)
       when config_key in [:inverted_opts, :fragment_store_opts, :tree_store_opts] do
    config
    |> Keyword.get(config_key, [])
    |> Keyword.merge(value)
  end

  defp merge_opts(_config_key, _config, value), do: value

  @doc false
  def shared_store_opts(opts),
    do: Keyword.take(opts, [:repo, :prefix, :migrate?, :bm25?, :package, :package_version])
end
