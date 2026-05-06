defmodule Exograph.Package do
  @moduledoc """
  Source package identity for multi-package indexes.
  """

  @type ecosystem :: atom() | String.t()

  @type t :: %__MODULE__{
          id: String.t(),
          ecosystem: ecosystem(),
          name: String.t(),
          metadata: map()
        }

  defstruct id: nil, ecosystem: :hex, name: nil, metadata: %{}

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    ecosystem = Map.get(attrs, :ecosystem, :hex)
    name = Map.fetch!(attrs, :name)

    %__MODULE__{
      id: Map.get(attrs, :id) || id(ecosystem, name),
      ecosystem: ecosystem,
      name: name,
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @spec id(ecosystem(), String.t()) :: String.t()
  def id(ecosystem, name), do: "#{ecosystem}:#{name}"
end
