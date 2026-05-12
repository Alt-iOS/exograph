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
    :line,
    :column
  ]

  def fields, do: @fields

  def new(module, file, symbol, fragment_id) do
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
      line: symbol.line,
      column: symbol.column
    })
  end
end
