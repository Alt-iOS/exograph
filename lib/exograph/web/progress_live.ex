defmodule Exograph.Web.ProgressLive do
  @moduledoc false

  use Exograph.Web, :live_view

  alias Exograph.Hex.Progress

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Progress.subscribe()
      Process.send_after(self(), :tick, 1000)
    end

    {:ok, assign(socket, progress: Progress.get())}
  end

  @impl true
  def handle_info({:progress, progress}, socket) do
    {:noreply, assign(socket, progress: progress)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, assign(socket, progress: Progress.get())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-200">
      <div class="max-w-2xl mx-auto px-6 py-10">
        <div class="flex items-center gap-3 mb-6">
          <h1 class="text-lg font-bold text-white">Hex Indexer</h1>
          <span class={["px-2 py-0.5 text-xs rounded-full", status_badge(@progress.state)]}>
            {status_label(@progress.state)}
          </span>
        </div>

        <div :if={@progress.state == :idle} class="text-zinc-500 text-center py-16 text-sm">
          <p>No indexing in progress.</p>
          <p class="mt-2">
            Run
            <code class="text-zinc-400 bg-zinc-800 px-1 py-0.5 rounded text-xs">mix exograph.index.hex --web</code>
          </p>
        </div>

        <div :if={@progress.state != :idle}>
          <div class="mb-6">
            <div class="flex items-baseline justify-between text-sm mb-1.5">
              <span class="text-zinc-400 tabular-nums">
                {@progress.processed}<span class="text-zinc-600">/{@progress.total}</span>
              </span>
              <span class="text-zinc-400 tabular-nums">{pct(@progress)}%</span>
            </div>
            <div class="h-2 bg-zinc-800 rounded-full overflow-hidden">
              <div
                class={[
                  "h-full rounded-full transition-all duration-500",
                  if(@progress.state == :done, do: "bg-green-500", else: "bg-blue-500")
                ]}
                style={"width: #{pct(@progress)}%"}
              />
            </div>
            <div class="flex justify-between text-xs text-zinc-600 mt-1.5 tabular-nums">
              <span>{rate(@progress)} pkg/s</span>
              <span :if={@progress.state == :running}>ETA {eta(@progress)}</span>
              <span :if={@progress.state == :done}>{elapsed(@progress)}</span>
            </div>
          </div>

          <div class="flex gap-3 mb-6">
            <.stat value={@progress.ok} label="Indexed" class="text-green-400" />
            <.stat value={@progress.skipped} label="Skipped" class="text-zinc-500" />
            <.stat value={@progress.errors} label="Failed" class="text-red-400" />
          </div>

          <div
            :if={@progress.current && @progress.state == :running}
            class="flex items-center gap-2 text-sm text-zinc-500 mb-4"
          >
            <span class="w-3 h-3 border-2 border-blue-400 border-t-transparent rounded-full animate-spin" />
            <span class="font-mono text-zinc-300">
              {@progress.current.name}<span class="text-zinc-600">@{@progress.current.version}</span>
            </span>
          </div>

          <div class="rounded-lg border border-zinc-800 overflow-hidden">
            <div class="px-3 py-2 text-xs font-medium text-zinc-500 bg-zinc-900/50 border-b border-zinc-800">
              Recent
            </div>
            <div class="max-h-80 overflow-y-auto scrollbar-thin scrollbar-thumb-zinc-700 scrollbar-track-transparent divide-y divide-zinc-800/40">
              <div
                :for={item <- @progress.recent}
                class="flex items-center justify-between px-3 py-1.5 text-sm"
              >
                <div class="flex items-center gap-2">
                  <span class={dot(item.status)} />
                  <span class="font-mono text-xs text-zinc-300">
                    {item.name}<span class="text-zinc-600">@{item.version}</span>
                  </span>
                </div>
                <span class={["text-xs", status_color(item.status)]}>
                  {status_text(item.status)}
                </span>
              </div>
              <div :if={@progress.recent == []} class="px-3 py-6 text-center text-zinc-600 text-xs">
                Waiting…
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:value, :integer, required: true)
  attr(:label, :string, required: true)
  attr(:class, :string, default: "")

  defp stat(assigns) do
    ~H"""
    <div class="flex-1 rounded-lg border border-zinc-800 px-3 py-2">
      <div class={["text-xl font-bold tabular-nums", @class]}>{@value}</div>
      <div class="text-xs text-zinc-600">{@label}</div>
    </div>
    """
  end

  defp pct(%{total: 0}), do: 0
  defp pct(%{processed: p, total: t}), do: Float.round(p / t * 100, 1)

  defp rate(%{processed: 0}), do: "—"

  defp rate(%{processed: p, started_at: started}) do
    elapsed_s = (System.monotonic_time(:millisecond) - started) / 1000
    if elapsed_s > 0, do: Float.round(p / elapsed_s, 1), else: "—"
  end

  defp eta(%{processed: p, total: t, started_at: started}) when p > 0 do
    elapsed_s = (System.monotonic_time(:millisecond) - started) / 1000
    rate = p / max(elapsed_s, 0.1)
    format_duration((t - p) / rate)
  end

  defp eta(_), do: "—"

  defp elapsed(%{started_at: s, finished_at: f}) when is_integer(s) and is_integer(f) do
    format_duration((f - s) / 1000)
  end

  defp elapsed(_), do: "—"

  defp format_duration(s) when s < 60, do: "#{round(s)}s"

  defp format_duration(s) when s < 3600,
    do: "#{div(round(s), 60)}m#{String.pad_leading("#{rem(round(s), 60)}", 2, "0")}s"

  defp format_duration(s) do
    h = div(round(s), 3600)
    m = div(rem(round(s), 3600), 60)
    "#{h}h#{String.pad_leading("#{m}", 2, "0")}m"
  end

  defp status_badge(:idle), do: "bg-zinc-800 text-zinc-500"
  defp status_badge(:running), do: "bg-blue-500/15 text-blue-400"
  defp status_badge(:done), do: "bg-green-500/15 text-green-400"

  defp status_label(:idle), do: "Idle"
  defp status_label(:running), do: "Running"
  defp status_label(:done), do: "Complete"

  defp dot(:ok), do: "w-1.5 h-1.5 rounded-full bg-green-400"
  defp dot(:skipped), do: "w-1.5 h-1.5 rounded-full bg-zinc-600"
  defp dot({:error, _}), do: "w-1.5 h-1.5 rounded-full bg-red-400"

  defp status_color(:ok), do: "text-green-500/70"
  defp status_color(:skipped), do: "text-zinc-600"
  defp status_color({:error, _}), do: "text-red-400"

  defp status_text(:ok), do: "indexed"
  defp status_text(:skipped), do: "skipped"
  defp status_text({:error, reason}), do: "failed: #{inspect(reason, limit: 40)}"
end
