defmodule Exograph.Reference do
  @moduledoc "Syntactic reference extracted from source."

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

  def new(file, reference, fragment_id \\ nil) do
    Exograph.SymbolFact.new(__MODULE__, file, reference, fragment_id)
  end
end
