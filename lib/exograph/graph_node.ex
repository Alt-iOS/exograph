defmodule Exograph.GraphNode do
  @moduledoc "Reach-derived semantic graph node."

  @type t :: %__MODULE__{
          id: integer() | nil,
          package_id: integer() | nil,
          package_version_id: integer() | nil,
          file_id: integer() | nil,
          fragment_id: integer() | nil,
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
    kind = Map.get(attrs, :kind)
    external_id = Map.get(attrs, :external_id)

    temp_id = :erlang.phash2({external_id, qualified_name, kind})

    struct(__MODULE__, Map.put_new(attrs, :id, temp_id))
  end
end
