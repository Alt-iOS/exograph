defmodule Exograph.GraphNode do
  @moduledoc "Reach-derived semantic graph node."

  @type t :: %__MODULE__{
          id: String.t(),
          package_id: String.t() | nil,
          package_version_id: String.t() | nil,
          file_id: String.t() | nil,
          fragment_id: String.t() | nil,
          engine: String.t(),
          external_id: String.t() | nil,
          kind: atom(),
          module: String.t() | nil,
          name: String.t() | nil,
          arity: non_neg_integer() | nil,
          qualified_name: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :fragment_id,
    :external_id,
    :kind,
    :module,
    :name,
    :arity,
    :qualified_name,
    :line,
    :column,
    engine: "reach",
    metadata: %{}
  ]

  def new(attrs) do
    attrs = Map.new(attrs)
    qualified_name = Map.fetch!(attrs, :qualified_name)

    struct(
      __MODULE__,
      Map.put_new_lazy(attrs, :id, fn ->
        id(
          Map.get(attrs, :package_version_id),
          Map.get(attrs, :file_id),
          Map.get(attrs, :kind),
          qualified_name,
          Map.get(attrs, :line),
          Map.get(attrs, :column)
        )
      end)
    )
  end

  def id(package_version_id, file_id, kind, qualified_name, line, column) do
    :crypto.hash(
      :blake2b,
      :erlang.term_to_binary({package_version_id, file_id, kind, qualified_name, line, column})
    )
    |> Base.encode16(case: :lower)
  end
end
