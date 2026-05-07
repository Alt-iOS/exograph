defmodule Exograph.Postgres.Options do
  @moduledoc false

  alias Exograph.{Package, PackageVersion, Postgres}

  def repo(opts), do: Postgres.fetch_repo!(opts)

  def prefix(opts), do: Keyword.get(opts, :prefix, "exograph")

  def package(opts) do
    case Keyword.get(opts, :package) do
      nil -> nil
      %Package{} = package -> package
      attrs -> Package.new(attrs)
    end
  end

  def package_version(opts) do
    case Keyword.get(opts, :package_version) do
      nil -> nil
      %PackageVersion{} = version -> version
      attrs -> PackageVersion.new(attrs)
    end
  end

  def store(module, opts) do
    migrate(opts)

    struct(module,
      repo: repo(opts),
      prefix: prefix(opts),
      package: package(opts),
      package_version: package_version(opts)
    )
  end

  def hydrate_fragment(record, source, path) do
    record
    |> Map.put(:source, source)
    |> Map.put(:file, path)
    |> Exograph.Postgres.FragmentRecord.to_fragment()
  end

  def files_source(prefix), do: {"#{prefix}_files", Exograph.Postgres.FileRecord}
  def fragments_source(prefix), do: "#{prefix}_fragments"
  def comments_source(prefix), do: {"#{prefix}_comments", Exograph.Postgres.CommentRecord}

  def definitions_source(prefix),
    do: {"#{prefix}_definitions", Exograph.Postgres.DefinitionRecord}

  def references_source(prefix), do: {"#{prefix}_references", Exograph.Postgres.ReferenceRecord}
  def graph_nodes_source(prefix), do: {"#{prefix}_graph_nodes", Exograph.Postgres.GraphNodeRecord}
  def call_edges_source(prefix), do: {"#{prefix}_call_edges", Exograph.Postgres.CallEdgeRecord}

  def migrate(opts) do
    if Keyword.get(opts, :migrate?, false), do: Postgres.migrate!(opts)
  end
end
