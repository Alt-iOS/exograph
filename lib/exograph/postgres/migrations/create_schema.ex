defmodule Exograph.Postgres.Migrations.CreateSchema do
  @moduledoc false

  use Ecto.Migration

  def up do
    create_if_not_exists table(name("schema_migrations"), primary_key: false) do
      add(:version, :bigint, primary_key: true)
      add(:inserted_at, :naive_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists table(name("packages"), primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:ecosystem, :text, null: false)
      add(:name, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(name("packages"), [:ecosystem, :name],
        name: index_name("packages", "ecosystem_name")
      )
    )

    create_if_not_exists table(name("package_versions"), primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:package_id, references(name("packages"), type: :text, on_delete: :delete_all),
        null: false
      )

      add(:version, :text, null: false)
      add(:source_ref, :text)
      add(:checksum, :text)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(name("package_versions"), [:package_id, :version],
        name: index_name("package_versions", "package_version")
      )
    )

    create_if_not_exists table(name("files"), primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:package_id, references(name("packages"), type: :text, on_delete: :delete_all))

      add(
        :package_version_id,
        references(name("package_versions"), type: :text, on_delete: :delete_all)
      )

      add(:path, :text, null: false)
      add(:source, :text, null: false)
      add(:sha256, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      index(name("files"), [:package_version_id, :path],
        name: index_name("files", "package_path")
      )
    )

    create_if_not_exists table(name("fragments"), primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:package_id, references(name("packages"), type: :text, on_delete: :delete_all))

      add(
        :package_version_id,
        references(name("package_versions"), type: :text, on_delete: :delete_all)
      )

      add(:file_id, references(name("files"), type: :text, on_delete: :delete_all))
      add(:ast, :binary, null: false)
      add(:kind, :text, null: false)
      add(:module, :text)
      add(:name, :text)
      add(:arity, :integer)
      add(:line, :integer, null: false)
      add(:end_line, :integer)
      add(:mass, :integer, null: false)
      add(:exact_hash, :binary)
      add(:abstract_hash, :binary)
      add(:term_hashes, {:array, :bigint}, null: false, default: [])
      add(:terms_blob, :binary, null: false)
      add(:sub_hashes, {:array, :bigint}, null: false, default: [])
      add(:symbols_blob, :binary, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      index(name("fragments"), [:term_hashes],
        using: :gin,
        name: index_name("fragments", "terms_gin")
      )
    )

    create_if_not_exists(
      index(name("fragments"), [:package_id, :package_version_id],
        name: index_name("fragments", "package")
      )
    )

    create_if_not_exists(
      index(name("fragments"), [:file_id], name: index_name("fragments", "file"))
    )

    create_if_not_exists table(name("tree_nodes"), primary_key: false) do
      add(:fragment_id, references(name("fragments"), type: :text, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :integer, null: false, primary_key: true)
      add(:parent_id, :integer)
      add(:ordinal, :integer, null: false)
      add(:role, :text)
      add(:kind, :text, null: false)
      add(:label, :text)
      add(:line, :integer, null: false)
      add(:preorder, :integer, null: false)
      add(:postorder, :integer, null: false)
      add(:depth, :integer, null: false)
    end

    create_if_not_exists(
      index(name("tree_nodes"), [:fragment_id], name: index_name("tree_nodes", "fragment"))
    )
  end

  def down do
    drop_if_exists(table(name("tree_nodes")))
    drop_if_exists(table(name("fragments")))
    drop_if_exists(table(name("files")))
    drop_if_exists(table(name("package_versions")))
    drop_if_exists(table(name("packages")))
    drop_if_exists(table(name("schema_migrations")))
  end

  defp name(suffix), do: "#{table_prefix()}_#{suffix}"
  defp index_name(table, suffix), do: "#{table_prefix()}_#{table}_#{suffix}_idx"

  defp table_prefix do
    Application.fetch_env!(:exograph, __MODULE__)[:prefix]
  end
end
