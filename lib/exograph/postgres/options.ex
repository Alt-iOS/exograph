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

  def migrate(opts) do
    if Keyword.get(opts, :migrate?, false), do: Postgres.migrate!(opts)
  end
end
