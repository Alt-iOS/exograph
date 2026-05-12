defmodule Exograph.Comment do
  @moduledoc "Source comment extracted from a file."

  @type t :: %__MODULE__{
          id: integer() | nil,
          package_id: integer() | nil,
          package_version_id: integer() | nil,
          file_id: integer(),
          fragment_id: integer() | nil,
          text: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil
        }

  defstruct [:id, :package_id, :package_version_id, :file_id, :fragment_id, :text, :line, :column]

  def new(file, comment, fragment_id \\ nil) do
    %__MODULE__{
      id: nil,
      package_id: file.package_id,
      package_version_id: file.package_version_id,
      file_id: file.id,
      fragment_id: fragment_id,
      text: comment.text,
      line: comment.line,
      column: comment.column
    }
  end
end
