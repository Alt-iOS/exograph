defmodule Exograph.Postgres.Migrations.AddSearchFields do
  @moduledoc false

  use Ecto.Migration

  def up do
    alter table(name("files")) do
      add_if_not_exists(:comments_text, :text, null: false, default: "")
    end
  end

  def down do
    alter table(name("files")) do
      remove_if_exists(:comments_text, :text)
    end
  end

  defp name(suffix), do: "#{table_prefix()}_#{suffix}"

  defp table_prefix do
    Application.fetch_env!(:exograph, __MODULE__)[:prefix]
  end
end
