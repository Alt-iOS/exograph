defmodule Exograph.Fragment do
  @moduledoc """
  Searchable code unit.

  Fragments are the bridge between source parsing, structural terms, near-duplicate
  fingerprints, and the inverted index backend.
  """

  @type id :: non_neg_integer() | binary()

  @type t :: %__MODULE__{
          id: id() | nil,
          file: String.t(),
          source: String.t() | nil,
          ast: Macro.t(),
          kind: atom(),
          module: String.t() | nil,
          name: String.t() | nil,
          arity: non_neg_integer() | nil,
          line: non_neg_integer(),
          end_line: non_neg_integer() | nil,
          mass: non_neg_integer(),
          exact_hash: binary() | nil,
          abstract_hash: binary() | nil,
          terms: MapSet.t(String.t()),
          sub_hashes: MapSet.t(integer()),
          defs: MapSet.t(String.t()),
          refs: MapSet.t(String.t()),
          modules: MapSet.t(String.t()),
          functions: MapSet.t(String.t()),
          aliases: MapSet.t(String.t()),
          structs: MapSet.t(String.t()),
          atoms: MapSet.t(String.t())
        }

  defstruct id: nil,
            file: "",
            source: nil,
            ast: nil,
            kind: :unknown,
            module: nil,
            name: nil,
            arity: nil,
            line: 0,
            end_line: nil,
            mass: 0,
            exact_hash: nil,
            abstract_hash: nil,
            terms: MapSet.new(),
            sub_hashes: MapSet.new(),
            defs: MapSet.new(),
            refs: MapSet.new(),
            modules: MapSet.new(),
            functions: MapSet.new(),
            aliases: MapSet.new(),
            structs: MapSet.new(),
            atoms: MapSet.new()
end
