defmodule Exograph.Web.Layouts do
  @moduledoc false
  use Exograph.Web, :html

  embed_templates("layouts/*")

  def css_path do
    outdir = Volt.Config.build().outdir |> to_string()
    css_dir = Path.join(outdir, "css")

    case File.ls(css_dir) do
      {:ok, files} ->
        case Enum.find(files, &String.starts_with?(&1, "app")) do
          nil -> "/assets/css/app.css"
          file -> "/assets/css/#{file}"
        end

      _ ->
        "/assets/css/app.css"
    end
  end
end
