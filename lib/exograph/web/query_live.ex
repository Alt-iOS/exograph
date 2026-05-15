defmodule Exograph.Web.QueryLive do
  @moduledoc false

  use Exograph.Web, :live_view

  import Exograph.Web.ResultFormatter, only: [display_name: 1, badge_class: 1]

  alias Exograph.Web.QueryExecutor
  alias Exograph.Web.ResultFormatter

  @default_query """
  from(f in Fragment,
    where: matches(f, "def _ do ... end"),
    limit: 20
  )\
  """

  @examples [
    {"Pattern search", ~S'from(f in Fragment, where: matches(f, "Repo.get!(_, _)"), limit: 20)'},
    {"GenServer callbacks",
     ~S'from(f in Fragment, where: matches(f, "def handle_call(_, _, _) do ... end"), limit: 20)'},
    {"Functions calling Enum.map",
     ~S"""
     from(f in Fragment,
       join: r in assoc(f, :references),
       where: r.qualified_name == "Enum.map/2",
       where: f.kind == :def,
       limit: 20)
     """},
    {"Public API definitions",
     ~S'from(d in Definition, where: d.kind == :def, where: prefix_search(d.name, "fetch"))'},
    {"Call graph: who calls Repo.transaction",
     ~S'from(e in CallEdge, where: e.callee_qualified_name == "Ecto.Repo.transaction/2", limit: 20)'},
    {"Functions with TODO comments",
     ~S'from(f in Fragment, where: matches(f, "def _ do ... end"), where: contains(f, "# TODO"), limit: 20)'}
  ]

  @impl true
  def mount(_params, _session, socket) do
    index = Application.get_env(:exograph, :web_index)
    prefix = Application.get_env(:exograph, :web_prefix)

    {:ok,
     assign(socket,
       index: index,
       prefix: prefix,
       query: @default_query,
       examples: @examples,
       results: nil,
       error: nil,
       elapsed_ms: nil,
       result_count: nil
     )}
  end

  @impl true
  def handle_event("set_query", %{"query" => query}, socket) do
    {:noreply, push_event(socket, "set_editor_value", %{value: String.trim(query)})}
  end

  @impl true
  def handle_event("run", %{"query" => query}, socket) do
    socket = assign(socket, query: query, error: nil, results: nil, elapsed_ms: nil)

    case QueryExecutor.execute(socket.assigns.index, query) do
      {:ok, results, elapsed_ms} ->
        {:noreply,
         socket
         |> assign(
           results: ResultFormatter.format(results),
           result_count: length(results),
           elapsed_ms: elapsed_ms
         )
         |> push_event("set_diagnostics", %{markers: []})}

      {:error, %{message: message, markers: markers}} ->
        {:noreply,
         socket
         |> assign(error: message)
         |> push_event("set_diagnostics", %{markers: markers})}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, error: message)}
    end
  end

  @impl true
  def handle_event("completion", %{"hint" => hint}, socket) do
    items = Exograph.Web.Completion.complete(hint, socket.assigns.index)
    {:reply, %{items: items}, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <header class="flex items-center justify-between px-6 py-3 border-b border-zinc-800">
        <div class="flex items-center gap-3">
          <h1 class="text-lg font-semibold tracking-tight">Exograph</h1>
          <span class="text-xs text-zinc-500">{@prefix}</span>
        </div>
        <div class="flex items-center gap-4 text-sm text-zinc-400">
          <span :if={@result_count} class="tabular-nums">
            <span :if={@result_count == 1}>1 result</span>
            <span :if={@result_count != 1}>{@result_count} results</span>
            across {length(@results || [])}
            <span :if={length(@results || []) == 1}>package</span>
            <span :if={length(@results || []) != 1}>packages</span>
            in {@elapsed_ms}ms
          </span>
          <button
            id="run-btn"
            phx-hook="RunButton"
            class="px-3 py-1.5 text-sm font-medium bg-blue-600 text-white rounded-md hover:bg-blue-500 cursor-pointer transition-colors"
          >
            Run ⌘↵
          </button>
        </div>
      </header>

      <div class="flex flex-col flex-1 min-h-0">
        <div class="h-[200px] border-b border-zinc-800">
          <div
            id="editor"
            phx-hook="Editor"
            phx-update="ignore"
            class="h-full"
            data-query={@query}
          />
        </div>

        <div class="flex-1 overflow-auto p-4 space-y-3">
          <div :if={@error} class="p-4 text-red-400 font-mono text-sm whitespace-pre-wrap">
            {@error}
          </div>

          <div :for={group <- (@results || [])} class="rounded-lg border border-zinc-800 overflow-hidden">
            <div class="flex items-center gap-3 px-4 py-2.5 bg-zinc-900 border-b border-zinc-800">
              <span class="text-sm font-semibold text-zinc-200">{group.package}</span>
              <span class="text-xs text-zinc-500 bg-zinc-800 rounded-full px-2 py-0.5 tabular-nums">
                {group.count} results
              </span>
            </div>

            <div class="divide-y divide-zinc-800">
              <div :for={file_group <- group.files}>
                <div class="flex items-center gap-2 px-4 py-2 bg-zinc-900/40 border-b border-zinc-800/50">
                  <.icon name="heroicons:document-text" class="w-3.5 h-3.5 text-zinc-500 shrink-0" />
                  <span class="text-blue-400 font-mono text-xs">{file_group.file}</span>
                </div>

                <div class="divide-y divide-zinc-800/40">
                  <div :for={result <- file_group.results} class="px-4 py-3">
                    <div class="flex items-center gap-2 mb-2 flex-wrap">
                      <span class={"inline-flex items-center px-1.5 py-0.5 text-xs rounded font-medium " <> badge_class(result.kind)}>
                        {to_string(result.kind)}
                      </span>
                      <span class="text-zinc-200 font-mono text-sm">{display_name(result)}</span>
                      <span :if={result.module} class="text-zinc-500 text-xs font-mono">
                        {result.module}
                      </span>
                      <span class="ml-auto text-zinc-600 text-xs tabular-nums">
                        line {result.line}
                      </span>
                      <span
                        :if={result.joined_label}
                        class="text-zinc-500 text-xs font-mono ml-2"
                      >
                        {result.joined_label}
                      </span>
                    </div>

                    <div :if={result.preview} class="code-preview rounded border border-zinc-800 overflow-hidden py-1">
                      <div
                        :for={{line_num, html, is_matched} <- result.preview}
                        class={"flex font-mono" <> if(is_matched, do: " bg-blue-900/20 border-l-2 border-l-blue-500", else: "")}
                      >
                        <span class="w-10 text-right pr-3 text-zinc-600 select-none shrink-0 bg-zinc-900/50 border-r border-zinc-800/50 tabular-nums">{line_num}</span><code class="px-3 flex-1 overflow-x-hidden text-zinc-300 whitespace-pre">{raw(html)}</code>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div :if={@results == []} class="p-8 text-center text-zinc-500">No results</div>
          <div :if={is_nil(@results) && is_nil(@error)} class="px-6 py-8">
            <p class="text-sm text-zinc-500 mb-4">Try an example:</p>
            <div class="flex flex-wrap gap-2">
              <button
                :for={{label, query} <- @examples}
                phx-click="set_query"
                phx-value-query={query}
                class="px-3 py-1.5 text-xs font-medium text-zinc-300 bg-zinc-800 border border-zinc-700 rounded-md hover:bg-zinc-700 hover:border-zinc-600 cursor-pointer transition-colors"
              >
                {label}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
