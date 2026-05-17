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
    <div class="min-h-screen bg-zinc-950 text-zinc-200 p-8">
      <div class="max-w-4xl mx-auto">
        <div class="flex items-center gap-3 mb-8">
          <h1 class="text-2xl font-bold text-white">Hex Indexer</h1>
          <span class={[
            "px-2 py-0.5 text-xs rounded-full font-medium",
            status_badge_class(@progress.state)
          ]}>
            {status_label(@progress.state)}
          </span>
        </div>

        <div :if={@progress.state == :idle} class="text-zinc-500 text-center py-20">
          <.icon name="heroicons:inbox" class="w-12 h-12 mx-auto mb-4 text-zinc-700" />
          <p>No indexing in progress.</p>
          <p class="text-sm mt-2">
            Run <code class="text-zinc-400 bg-zinc-800 px-1.5 py-0.5 rounded">mix exograph.index.hex --web</code>
            to start indexing with live progress.
          </p>
        </div>

        <div :if={@progress.state != :idle}>
          <!-- Progress bar -->
          <div class="mb-8">
            <div class="flex justify-between text-sm mb-2">
              <span>{@progress.processed} / {@progress.total} packages</span>
              <span>{pct(@progress)}%</span>
            </div>
            <div class="w-full h-3 bg-zinc-800 rounded-full overflow-hidden">
              <div
                class="h-full bg-gradient-to-r from-blue-600 to-blue-400 transition-all duration-300 rounded-full"
                style={"width: #{pct(@progress)}%"}
              >
              </div>
            </div>
            <div class="flex justify-between text-xs text-zinc-500 mt-2">
              <span>{rate(@progress)} pkg/s</span>
              <span :if={@progress.state == :running}>ETA {eta(@progress)}</span>
              <span :if={@progress.state == :done}>
                Finished in {elapsed(@progress)}
              </span>
            </div>
          </div>

          <!-- Stats cards -->
          <div class="grid grid-cols-4 gap-4 mb-8">
            <div class="bg-zinc-900 rounded-lg p-4 border border-zinc-800">
              <div class="text-2xl font-bold text-white">{@progress.processed}</div>
              <div class="text-xs text-zinc-500">Processed</div>
            </div>
            <div class="bg-zinc-900 rounded-lg p-4 border border-zinc-800">
              <div class="text-2xl font-bold text-green-400">{@progress.ok}</div>
              <div class="text-xs text-zinc-500">Indexed</div>
            </div>
            <div class="bg-zinc-900 rounded-lg p-4 border border-zinc-800">
              <div class="text-2xl font-bold text-zinc-500">{@progress.skipped}</div>
              <div class="text-xs text-zinc-500">Skipped</div>
            </div>
            <div class="bg-zinc-900 rounded-lg p-4 border border-zinc-800">
              <div class="text-2xl font-bold text-red-400">{@progress.errors}</div>
              <div class="text-xs text-zinc-500">Failed</div>
            </div>
          </div>

          <!-- Current -->
          <div
            :if={@progress.current && @progress.state == :running}
            class="mb-6 flex items-center gap-2 text-sm"
          >
            <div class="w-4 h-4 border-2 border-blue-400 border-t-transparent rounded-full animate-spin">
            </div>
            <span class="text-zinc-400">Indexing</span>
            <span class="text-blue-400 font-mono">
              {@progress.current.name}@{@progress.current.version}
            </span>
          </div>

          <!-- Recent packages -->
          <div class="bg-zinc-900 rounded-lg border border-zinc-800">
            <div class="px-4 py-3 border-b border-zinc-800 text-sm font-medium text-zinc-400">
              Recent activity
            </div>
            <div class="max-h-96 overflow-y-auto scrollbar-thin scrollbar-thumb-zinc-700 scrollbar-track-transparent">
              <div
                :for={item <- @progress.recent}
                class="flex items-center justify-between px-4 py-2 border-b border-zinc-800/50 last:border-0"
              >
                <div class="flex items-center gap-2">
                  <span class={status_dot_class(item.status)}></span>
                  <span class="font-mono text-sm text-zinc-300">
                    {item.name}<span class="text-zinc-600">@{item.version}</span>
                  </span>
                </div>
                <span class={["text-xs", status_text_class(item.status)]}>
                  {status_text(item.status)}
                </span>
              </div>
              <div
                :if={@progress.recent == []}
                class="px-4 py-8 text-center text-zinc-600 text-sm"
              >
                Waiting for packages...
              </div>
            </div>
          </div>
        </div>
      </div>
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
    remaining = (t - p) / rate
    format_duration(remaining)
  end

  defp eta(_), do: "—"

  defp elapsed(%{started_at: s, finished_at: f}) when is_integer(s) and is_integer(f) do
    format_duration((f - s) / 1000)
  end

  defp elapsed(_), do: "—"

  defp format_duration(seconds) when seconds < 60, do: "#{round(seconds)}s"

  defp format_duration(seconds) when seconds < 3600 do
    "#{div(round(seconds), 60)}m#{String.pad_leading("#{rem(round(seconds), 60)}", 2, "0")}s"
  end

  defp format_duration(seconds) do
    h = div(round(seconds), 3600)
    m = div(rem(round(seconds), 3600), 60)
    "#{h}h#{String.pad_leading("#{m}", 2, "0")}m"
  end

  defp status_badge_class(:idle), do: "bg-zinc-800 text-zinc-400"
  defp status_badge_class(:running), do: "bg-blue-900/50 text-blue-400"
  defp status_badge_class(:done), do: "bg-green-900/50 text-green-400"

  defp status_label(:idle), do: "Idle"
  defp status_label(:running), do: "Running"
  defp status_label(:done), do: "Complete"

  defp status_dot_class(:ok), do: "w-2 h-2 rounded-full bg-green-400"
  defp status_dot_class(:skipped), do: "w-2 h-2 rounded-full bg-zinc-600"
  defp status_dot_class({:error, _}), do: "w-2 h-2 rounded-full bg-red-400"

  defp status_text_class(:ok), do: "text-green-400"
  defp status_text_class(:skipped), do: "text-zinc-600"
  defp status_text_class({:error, _}), do: "text-red-400"

  defp status_text(:ok), do: "indexed"
  defp status_text(:skipped), do: "skipped"
  defp status_text({:error, reason}), do: "failed: #{inspect(reason, limit: 40)}"
end
