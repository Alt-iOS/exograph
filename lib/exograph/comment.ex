defmodule Exograph.Comment do
  @moduledoc "Source comment extracted from a file."

  @type t :: %__MODULE__{
          id: String.t(),
          package_id: String.t() | nil,
          package_version_id: String.t() | nil,
          file_id: String.t(),
          fragment_id: String.t() | nil,
          text: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil
        }

  defstruct [:id, :package_id, :package_version_id, :file_id, :fragment_id, :text, :line, :column]

  def new(file, comment, fragment_id \\ nil) do
    %__MODULE__{
      id: id(file.id, comment.line, comment.column, comment.text),
      package_id: file.package_id,
      package_version_id: file.package_version_id,
      file_id: file.id,
      fragment_id: fragment_id,
      text: comment.text,
      line: comment.line,
      column: comment.column
    }
  end

  def id(file_id, line, column, text) do
    :crypto.hash(:blake2b, :erlang.term_to_binary({file_id, line, column, text}))
    |> Base.encode16(case: :lower)
  end
end
