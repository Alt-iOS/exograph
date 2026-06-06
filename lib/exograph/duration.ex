defmodule Exograph.Duration do
  @moduledoc false

  def format(seconds) when seconds < 60, do: "#{round(seconds)}s"

  def format(seconds) when seconds < 3600 do
    total = round(seconds)
    minutes = div(total, 60)
    seconds = rem(total, 60)
    "#{minutes}m#{String.pad_leading("#{seconds}", 2, "0")}s"
  end

  def format(seconds) do
    total = round(seconds)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)
    "#{hours}h#{String.pad_leading("#{minutes}", 2, "0")}m"
  end
end
