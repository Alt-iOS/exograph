defmodule Exograph.Postgres.FragmentRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Exograph.Fragment

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_fragments" do
    field(:file, :string)
    field(:source, :string)
    field(:ast, :binary)

    field(:kind, Ecto.Enum,
      values: [:unknown, :module, :expression, :def, :defp, :defmacro, :defmacrop]
    )

    field(:module, :string)
    field(:name, :string)
    field(:arity, :integer)
    field(:line, :integer)
    field(:end_line, :integer)
    field(:mass, :integer)
    field(:exact_hash, :string)
    field(:abstract_hash, :string)
    field(:terms, {:array, :string}, default: [])
    field(:terms_text, :string, default: "")
    field(:sub_hashes, {:array, :integer}, default: [])
    field(:defs, {:array, :string}, default: [])
    field(:defs_text, :string, default: "")
    field(:refs, {:array, :string}, default: [])
    field(:refs_text, :string, default: "")
    field(:modules, {:array, :string}, default: [])
    field(:modules_text, :string, default: "")
    field(:functions, {:array, :string}, default: [])
    field(:functions_text, :string, default: "")
    field(:aliases, {:array, :string}, default: [])
    field(:aliases_text, :string, default: "")
    field(:structs, {:array, :string}, default: [])
    field(:structs_text, :string, default: "")
    field(:atoms, {:array, :string}, default: [])
    field(:atoms_text, :string, default: "")

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, __schema__(:fields))
    |> validate_required([:id, :file, :ast, :kind, :line, :mass])
  end

  def from_fragment(%Fragment{} = fragment) do
    %{
      id: fragment.id,
      file: fragment.file,
      source: fragment.source,
      ast: :erlang.term_to_binary(fragment.ast),
      kind: fragment.kind,
      module: fragment.module,
      name: fragment.name,
      arity: fragment.arity,
      line: fragment.line,
      end_line: fragment.end_line,
      mass: fragment.mass,
      exact_hash: fragment.exact_hash,
      abstract_hash: fragment.abstract_hash,
      terms: strings(fragment.terms),
      terms_text: joined(fragment.terms),
      sub_hashes: MapSet.to_list(fragment.sub_hashes),
      defs: strings(fragment.defs),
      defs_text: joined(fragment.defs),
      refs: strings(fragment.refs),
      refs_text: joined(fragment.refs),
      modules: strings(fragment.modules),
      modules_text: joined(fragment.modules),
      functions: strings(fragment.functions),
      functions_text: joined(fragment.functions),
      aliases: strings(fragment.aliases),
      aliases_text: joined(fragment.aliases),
      structs: strings(fragment.structs),
      structs_text: joined(fragment.structs),
      atoms: strings(fragment.atoms),
      atoms_text: joined(fragment.atoms)
    }
  end

  def to_fragment(%__MODULE__{} = record) do
    %Fragment{
      id: record.id,
      file: record.file,
      source: record.source,
      ast: :erlang.binary_to_term(record.ast),
      kind: record.kind,
      module: record.module,
      name: record.name,
      arity: record.arity,
      line: record.line,
      end_line: record.end_line,
      mass: record.mass,
      exact_hash: record.exact_hash,
      abstract_hash: record.abstract_hash,
      terms: mapset(record.terms),
      sub_hashes: mapset(record.sub_hashes),
      defs: mapset(record.defs),
      refs: mapset(record.refs),
      modules: mapset(record.modules),
      functions: mapset(record.functions),
      aliases: mapset(record.aliases),
      structs: mapset(record.structs),
      atoms: mapset(record.atoms)
    }
  end

  defp strings(set), do: set |> MapSet.to_list() |> Enum.sort()
  defp joined(set), do: set |> strings() |> Enum.join(" ")
  defp mapset(nil), do: MapSet.new()
  defp mapset(values), do: MapSet.new(values)
end
