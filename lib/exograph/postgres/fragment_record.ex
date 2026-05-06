defmodule Exograph.Postgres.FragmentRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Exograph.Fragment

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_fragments" do
    field(:package_id, :string)
    field(:package_version_id, :string)
    field(:file_id, :string)
    field(:file, :string, virtual: true)
    field(:source, :string, virtual: true)
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
    field(:exact_hash, :binary)
    field(:abstract_hash, :binary)
    field(:term_hashes, {:array, :integer}, default: [])
    field(:terms_blob, :binary)
    field(:sub_hashes, {:array, :integer}, default: [])
    field(:symbols_blob, :binary)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, __schema__(:fields))
    |> validate_required([:id, :ast, :kind, :line, :mass])
  end

  def from_fragment(%Fragment{} = fragment) do
    %{
      id: fragment.id,
      package_id: fragment.package_id,
      package_version_id: fragment.package_version_id,
      file_id: fragment.file_id,
      ast: compressed_binary(fragment.ast),
      kind: fragment.kind,
      module: fragment.module,
      name: fragment.name,
      arity: fragment.arity,
      line: fragment.line,
      end_line: fragment.end_line,
      mass: fragment.mass,
      exact_hash: encode_hash(fragment.exact_hash),
      abstract_hash: encode_hash(fragment.abstract_hash),
      term_hashes: term_hashes(fragment.terms),
      terms_blob: encode_terms(fragment.terms),
      sub_hashes: MapSet.to_list(fragment.sub_hashes),
      symbols_blob: encode_symbols(fragment)
    }
  end

  def to_fragment(%__MODULE__{} = record) do
    %Fragment{
      id: record.id,
      package_id: record.package_id,
      package_version_id: record.package_version_id,
      file_id: record.file_id,
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
      terms: decode_terms(record.terms_blob),
      sub_hashes: mapset(record.sub_hashes),
      defs: decoded_symbol(record.symbols_blob, :defs),
      refs: decoded_symbol(record.symbols_blob, :refs),
      modules: decoded_symbol(record.symbols_blob, :modules),
      functions: decoded_symbol(record.symbols_blob, :functions),
      aliases: decoded_symbol(record.symbols_blob, :aliases),
      structs: decoded_symbol(record.symbols_blob, :structs),
      atoms: decoded_symbol(record.symbols_blob, :atoms)
    }
  end

  defp encode_hash(nil), do: nil

  defp encode_hash(hash) when is_binary(hash) do
    case Base.decode16(hash, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> hash
    end
  end

  defp encode_hash(hash), do: to_string(hash)

  def term_hash(term) do
    <<hash::signed-64, _rest::binary>> = :crypto.hash(:sha256, term)
    hash
  end

  defp term_hashes(set), do: set |> strings() |> Enum.map(&term_hash/1)
  defp encode_terms(set), do: set |> strings() |> compressed_binary()
  defp decode_terms(nil), do: MapSet.new()
  defp decode_terms(blob), do: blob |> :erlang.binary_to_term() |> MapSet.new()

  defp encode_symbols(fragment) do
    %{
      defs: strings(fragment.defs),
      refs: strings(fragment.refs),
      modules: strings(fragment.modules),
      functions: strings(fragment.functions),
      aliases: strings(fragment.aliases),
      structs: strings(fragment.structs),
      atoms: strings(fragment.atoms)
    }
    |> compressed_binary()
  end

  defp decoded_symbol(nil, _key), do: MapSet.new()

  defp decoded_symbol(blob, key) do
    blob
    |> :erlang.binary_to_term()
    |> Map.fetch!(key)
    |> MapSet.new()
  end

  defp compressed_binary(term), do: :erlang.term_to_binary(term, [:compressed])
  defp strings(set), do: set |> MapSet.to_list() |> Enum.sort()
  defp mapset(nil), do: MapSet.new()
  defp mapset(values), do: MapSet.new(values)
end
