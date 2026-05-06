defmodule Exograph.Backend.Memory do
  @moduledoc """
  In-memory backend profile for tests, smoke checks, and ephemeral indexes.
  """

  @behaviour Exograph.Backend

  @impl true
  def config(_opts), do: Exograph.Backend.memory_config()
end
