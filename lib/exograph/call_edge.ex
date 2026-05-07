defmodule Exograph.CallEdge do
  @moduledoc "Reach-derived call graph edge."

  @type t :: %__MODULE__{
          id: String.t(),
          package_id: String.t() | nil,
          package_version_id: String.t() | nil,
          file_id: String.t() | nil,
          caller_node_id: String.t(),
          callee_node_id: String.t(),
          call_site_fragment_id: String.t() | nil,
          caller_qualified_name: String.t(),
          callee_qualified_name: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :caller_node_id,
    :callee_node_id,
    :call_site_fragment_id,
    :caller_qualified_name,
    :callee_qualified_name,
    :line,
    :column,
    metadata: %{}
  ]

  def new(attrs) do
    attrs = Map.new(attrs)

    struct(
      __MODULE__,
      Map.put_new_lazy(attrs, :id, fn ->
        id(
          Map.get(attrs, :package_version_id),
          Map.get(attrs, :file_id),
          Map.fetch!(attrs, :caller_qualified_name),
          Map.fetch!(attrs, :callee_qualified_name),
          Map.get(attrs, :line),
          Map.get(attrs, :column)
        )
      end)
    )
  end

  def id(package_version_id, file_id, caller_qualified_name, callee_qualified_name, line, column) do
    :crypto.hash(
      :blake2b,
      :erlang.term_to_binary(
        {package_version_id, file_id, caller_qualified_name, callee_qualified_name, line, column}
      )
    )
    |> Base.encode16(case: :lower)
  end
end
