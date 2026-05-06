defmodule Exograph.Scope do
  @moduledoc false

  def fragment?(fragment, opts) do
    package_id = Keyword.get(opts, :package_id)
    package_version_id = Keyword.get(opts, :package_version_id)
    package_version = Keyword.get(opts, :package_version)

    (is_nil(package_id) or fragment.package_id == package_id) and
      (is_nil(package_version_id) or fragment.package_version_id == package_version_id) and
      (is_nil(package_version) or fragment.package_version_id == package_version)
  end
end
