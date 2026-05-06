defmodule Exograph.Reference do
  @moduledoc "Syntactic reference extracted from source."

  @type t :: %__MODULE__{
          id: String.t(),
          package_id: String.t() | nil,
          package_version_id: String.t() | nil,
          file_id: String.t(),
          fragment_id: String.t() | nil,
          kind: atom(),
          module: String.t() | nil,
          name: String.t(),
          arity: non_neg_integer() | nil,
          qualified_name: String.t(),
          mfa_module: String.t() | nil,
          mfa_name: String.t() | nil,
          mfa_arity: non_neg_integer() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil
        }

  defstruct Exograph.SymbolFact.fields()

  def new(file, reference, fragment_id \\ nil) do
    Exograph.SymbolFact.new(__MODULE__, file, reference, fragment_id)
  end

  def id(file_id, qualified_name, line, column) do
    Exograph.SymbolFact.id(file_id, qualified_name, line, column)
  end
end
