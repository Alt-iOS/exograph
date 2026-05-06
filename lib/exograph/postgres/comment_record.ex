defmodule Exograph.Postgres.CommentRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.Comment

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix nil
  schema "exograph_comments" do
    field(:package_id, :string)
    field(:package_version_id, :string)
    field(:file_id, :string)
    field(:fragment_id, :string)
    field(:text, :string)
    field(:line, :integer)
    field(:column, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  def from_comment(%Comment{} = comment) do
    Map.take(comment, [
      :id,
      :package_id,
      :package_version_id,
      :file_id,
      :fragment_id,
      :text,
      :line,
      :column
    ])
  end
end
