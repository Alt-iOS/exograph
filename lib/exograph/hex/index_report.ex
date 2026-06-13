defmodule Exograph.Hex.IndexReport do
  @moduledoc false

  use JSONCodec

  defmodule Failure do
    @moduledoc false

    use JSONCodec

    defstruct [:name, :version, :reason]

    @type t :: %__MODULE__{
            name: String.t() | nil,
            version: String.t() | nil,
            reason: String.t()
          }
  end

  defstruct [:generated_at, :elapsed_ms, :ok, :skipped, :error, failures: []]

  @type t :: %__MODULE__{
          generated_at: String.t(),
          elapsed_ms: non_neg_integer(),
          ok: non_neg_integer(),
          skipped: non_neg_integer(),
          error: non_neg_integer(),
          failures: [Failure.t()]
        }
end
