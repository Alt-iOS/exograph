defmodule Exograph.Definition do
  @moduledoc "Syntactic definition extracted from source."

  @type t :: %__MODULE__{
          id: integer() | nil,
          package_id: integer() | nil,
          package_version_id: integer() | nil,
          file_id: integer(),
          fragment_id: integer() | nil,
          kind: atom(),
          module: String.t() | nil,
          name: String.t(),
          arity: non_neg_integer() | nil,
          qualified_name: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil
        }

  defstruct Exograph.SymbolFact.fields()

  def new(file, definition, fragment_id \\ nil) do
    Exograph.SymbolFact.new(__MODULE__, file, definition, fragment_id)
  end
end
