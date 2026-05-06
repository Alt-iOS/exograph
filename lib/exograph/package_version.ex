defmodule Exograph.PackageVersion do
  @moduledoc """
  Concrete package release/version identity for multi-version indexes.
  """

  alias Exograph.Package

  @type t :: %__MODULE__{
          id: String.t(),
          package_id: String.t(),
          ecosystem: Package.ecosystem(),
          package_name: String.t(),
          version: String.t(),
          source_ref: String.t() | nil,
          checksum: String.t() | nil,
          metadata: map()
        }

  defstruct id: nil,
            package_id: nil,
            ecosystem: :hex,
            package_name: nil,
            version: nil,
            source_ref: nil,
            checksum: nil,
            metadata: %{}

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    ecosystem = Map.get(attrs, :ecosystem, :hex)
    package_name = Map.get(attrs, :package_name) || Map.fetch!(attrs, :name)
    package_id = Map.get(attrs, :package_id) || Package.id(ecosystem, package_name)
    version = Map.fetch!(attrs, :version)

    %__MODULE__{
      id: Map.get(attrs, :id) || id(package_id, version),
      package_id: package_id,
      ecosystem: ecosystem,
      package_name: package_name,
      version: version,
      source_ref: Map.get(attrs, :source_ref),
      checksum: Map.get(attrs, :checksum),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @spec id(String.t(), String.t()) :: String.t()
  def id(package_id, version), do: "#{package_id}@#{version}"
end
