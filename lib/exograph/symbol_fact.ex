defmodule Exograph.SymbolFact do
  @moduledoc false

  @fields [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :fragment_id,
    :kind,
    :module,
    :name,
    :arity,
    :qualified_name,
    :mfa_module,
    :mfa_name,
    :mfa_arity,
    :line,
    :column
  ]

  def fields, do: @fields

  def new(module, file, symbol, fragment_id) do
    {mfa_module, mfa_name, mfa_arity} = split_mfa(symbol.mfa)

    struct(module, %{
      id: nil,
      package_id: file.package_id,
      package_version_id: file.package_version_id,
      file_id: file.id,
      fragment_id: fragment_id,
      kind: symbol.kind,
      module: symbol.module,
      name: symbol.name,
      arity: symbol.arity,
      qualified_name: symbol.qualified_name,
      mfa_module: mfa_module,
      mfa_name: mfa_name,
      mfa_arity: mfa_arity,
      line: symbol.line,
      column: symbol.column
    })
  end

  defp split_mfa({module, name, arity}) do
    {module |> Atom.to_string() |> String.replace_prefix("Elixir.", ""), Atom.to_string(name),
     arity}
  end

  defp split_mfa(_mfa), do: {nil, nil, nil}
end
