defmodule Exograph.File do
  @moduledoc """
  Source file stored once per package version.
  """

  require Sourceror

  @type t :: %__MODULE__{
          id: String.t(),
          package_id: String.t() | nil,
          package_version_id: String.t() | nil,
          path: String.t(),
          source: String.t(),
          comments_text: String.t(),
          sha256: String.t()
        }

  defstruct [:id, :package_id, :package_version_id, :path, :source, :comments_text, :sha256]

  def new(path, source, context \\ %{}) do
    package_version_id = Map.get(context, :package_version_id)
    sha256 = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    %__MODULE__{
      id: id(package_version_id, path, sha256),
      package_id: Map.get(context, :package_id),
      package_version_id: package_version_id,
      path: path,
      source: source,
      comments_text: comments_text(source),
      sha256: sha256
    }
  end

  def comments_text(source) do
    case Sourceror.string_to_quoted(source, []) do
      {:ok, _quoted, comments} ->
        Enum.map_join(comments, "\n", & &1.text)

      _error ->
        ""
    end
  end

  def id(package_version_id, path, sha256) do
    :crypto.hash(:blake2b, :erlang.term_to_binary({package_version_id, path, sha256}))
    |> Base.encode16(case: :lower)
  end
end
