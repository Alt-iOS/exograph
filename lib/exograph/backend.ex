defmodule Exograph.Backend do
  @moduledoc """
  High-level backend profile behaviour.

  A backend profile wires the three lower-level storage behaviours used by an
  Exograph index:

    * `Exograph.InvertedIndex`
    * `Exograph.FragmentStore`
    * `Exograph.TreeStore`

  Built-in profiles are available through `backend: :memory`,
  `backend: :postgres`, and `backend: :tantivy`. Custom profiles can implement
  this behaviour and be passed as `backend: MyBackendProfile`.
  """

  alias Exograph.Backend.{Memory, Postgres, Tantivy}
  alias Exograph.FragmentStore.Memory, as: MemoryFragmentStore
  alias Exograph.InvertedIndex.Memory, as: MemoryInvertedIndex
  alias Exograph.TreeStore.Memory, as: MemoryTreeStore

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
      nil -> default_profile(opts).config(opts)
      :memory -> Memory.config(opts)
      :postgres -> Postgres.config(opts)
      :tantivy -> Tantivy.config(opts)
      module when is_atom(module) -> module_profile_config(module, opts)
    end
  end

  defp default_profile(opts) do
    if Keyword.has_key?(opts, :repo), do: Postgres, else: Memory
  end

  defp module_profile_config(module, opts) do
    Code.ensure_loaded(module)

    if function_exported?(module, :config, 1) do
      module.config(opts)
    else
      [
        inverted: module,
        inverted_opts: shared_store_opts(opts),
        fragment_store: Keyword.get(opts, :fragment_store, MemoryFragmentStore),
        fragment_store_opts: shared_store_opts(opts),
        tree_store: Keyword.get(opts, :tree_store, MemoryTreeStore),
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

  @doc false
  def memory_config do
    [
      inverted: MemoryInvertedIndex,
      inverted_opts: [],
      fragment_store: MemoryFragmentStore,
      fragment_store_opts: [],
      tree_store: MemoryTreeStore,
      tree_store_opts: []
    ]
  end
end
