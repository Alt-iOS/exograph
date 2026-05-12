defmodule Exograph.Web.QueryLive do
  @moduledoc false

  use Phoenix.LiveView, layout: {Exograph.Web.Layouts, :app}

  @default_query """
  from(f in Fragment,
    where: matches(f, "def _ do ... end"),
    limit: 20
  )\
  """

  @impl true
  def mount(_params, _session, socket) do
    index = Application.get_env(:exograph, :web_index)
    prefix = Application.get_env(:exograph, :web_prefix)

    {:ok,
     assign(socket,
       index: index,
       prefix: prefix,
       query: @default_query,
       results: nil,
       error: nil,
       elapsed_ms: nil,
       result_count: nil
     )}
  end

  @impl true
  def handle_event("run", %{"query" => query}, socket) do
    socket = assign(socket, query: query, error: nil, results: nil, elapsed_ms: nil)

    case execute_query(socket.assigns.index, query) do
      {:ok, results, elapsed_ms} ->
        {:noreply,
         assign(socket,
           results: format_results(results),
           result_count: length(results),
           elapsed_ms: elapsed_ms
         )}

      {:error, message} ->
        {:noreply, assign(socket, error: message)}
    end
  end

  @impl true
  def handle_event("completion", %{"hint" => hint, "ref" => ref}, socket) do
    items = Exograph.Web.Completion.complete(hint, socket.assigns.index)

    {:reply, %{ref: ref, items: items}, socket}
  end

  defp execute_query(index, query_string) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        try do
          {parsed, _bindings} = Code.eval_string(query_string, [], __ENV__)
          run_parsed(index, parsed)
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case result do
      {:ok, results} -> {:ok, results, Float.round(elapsed_us / 1000, 1)}
      {:error, message} -> {:error, message}
    end
  end

  defp run_parsed(index, %Exograph.DSL.Query{} = query) do
    Exograph.all(index, query, limit: 50)
  end

  defp run_parsed(index, pattern) when is_binary(pattern) do
    Exograph.search(index, pattern, limit: 50)
  end

  defp run_parsed(_index, other) do
    {:error, "Expected a DSL query or pattern string, got: #{inspect(other, limit: 200)}"}
  end

  defp format_results(results) when is_list(results) do
    Enum.map(results, &format_result/1)
  end

  defp format_result(%Exograph.Hit{fragment: f, match: m}) do
    %{
      type: :fragment,
      file: Path.basename(f.file || ""),
      module: f.module,
      kind: f.kind,
      name: f.name,
      arity: f.arity,
      line: (m && m.line) || f.line
    }
  end

  defp format_result({%Exograph.Hit{fragment: f, match: m}, joined}) do
    base = %{
      type: :joined,
      file: Path.basename(f.file || ""),
      module: f.module,
      kind: f.kind,
      name: f.name,
      arity: f.arity,
      line: (m && m.line) || f.line
    }

    case joined do
      %Exograph.Definition{} = d ->
        Map.merge(base, %{joined_type: :definition, joined_name: d.qualified_name})

      %Exograph.Reference{} = r ->
        Map.merge(base, %{joined_type: :reference, joined_name: r.qualified_name})

      %Exograph.CallEdge{} = e ->
        Map.merge(base, %{
          joined_type: :call_edge,
          joined_name: "#{e.caller_qualified_name} → #{e.callee_qualified_name}"
        })

      _ ->
        base
    end
  end

  defp format_result({%Exograph.Hit{} = hit, j1, j2}) do
    format_result({hit, j1}) |> Map.put(:extra_joined, inspect(j2, limit: 80))
  end

  defp format_result({%Exograph.Hit{} = hit, j1, j2, j3}) do
    format_result({hit, j1})
    |> Map.put(:extra_joined, "#{inspect(j2, limit: 60)}, #{inspect(j3, limit: 60)}")
  end

  defp format_result(%Exograph.DefinitionHit{definition: d}) do
    %{
      type: :definition,
      kind: d.kind,
      name: d.qualified_name,
      line: d.line,
      file: nil,
      module: nil,
      arity: nil
    }
  end

  defp format_result(%Exograph.ReferenceHit{reference: r}) do
    %{
      type: :reference,
      kind: r.kind,
      name: r.qualified_name,
      line: r.line,
      file: nil,
      module: nil,
      arity: nil
    }
  end

  defp format_result(%Exograph.CallEdgeHit{call_edge: e}) do
    %{
      type: :call_edge,
      kind: :call,
      name: "#{e.caller_qualified_name} → #{e.callee_qualified_name}",
      line: e.line,
      file: nil,
      module: nil,
      arity: nil
    }
  end

  defp format_result(tuple) when is_tuple(tuple) do
    list = Tuple.to_list(tuple)

    case List.first(list) do
      %Exograph.Hit{} ->
        format_result({List.first(list), Enum.at(list, 1)})

      _ ->
        %{
          type: :unknown,
          name: inspect(tuple, limit: 200),
          kind: nil,
          line: nil,
          file: nil,
          module: nil,
          arity: nil
        }
    end
  end

  defp format_result(other) do
    %{
      type: :unknown,
      name: inspect(other, limit: 200),
      kind: nil,
      line: nil,
      file: nil,
      module: nil,
      arity: nil
    }
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
          <span :if={@result_count}>
            {to_string(@result_count)} results in {@elapsed_ms}ms
          </span>
          <button
            phx-click="run"
            phx-value-query={@query}
            class="px-3 py-1.5 text-sm font-medium bg-blue-600 text-white rounded-md hover:bg-blue-500 transition-colors"
          >
            Run
          </button>
        </div>
      </header>

      <div class="flex flex-1 min-h-0">
        <div class="flex flex-col w-full">
          <div class="border-b border-zinc-800">
            <div
              id="editor"
              phx-hook="Editor"
              phx-update="ignore"
              class="h-48"
              data-query={@query}
            />
          </div>

          <div class="flex-1 overflow-auto">
            <div :if={@error} class="p-4 text-red-400 font-mono text-sm whitespace-pre-wrap">{@error}</div>

            <table :if={@results && @results != []} class="w-full text-sm">
              <thead class="text-xs text-zinc-500 uppercase tracking-wider">
                <tr class="border-b border-zinc-800">
                  <th class="px-4 py-2 text-left font-medium">Kind</th>
                  <th class="px-4 py-2 text-left font-medium">Module</th>
                  <th class="px-4 py-2 text-left font-medium">Name</th>
                  <th class="px-4 py-2 text-left font-medium">File</th>
                  <th class="px-4 py-2 text-right font-medium">Line</th>
                  <th :if={has_joined?(@results)} class="px-4 py-2 text-left font-medium">Joined</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @results} class="border-b border-zinc-800/50 hover:bg-zinc-900/50">
                  <td class="px-4 py-2">
                    <span class={"inline-block px-1.5 py-0.5 text-xs rounded #{kind_color(row.kind)}"}>{to_string(row.kind)}</span>
                  </td>
                  <td class="px-4 py-2 text-zinc-400 font-mono text-xs">{row.module}</td>
                  <td class="px-4 py-2 font-mono text-xs">{display_name(row)}</td>
                  <td class="px-4 py-2 text-zinc-500 text-xs">{row.file}</td>
                  <td class="px-4 py-2 text-right text-zinc-500 tabular-nums">{row.line}</td>
                  <td :if={has_joined?(@results)} class="px-4 py-2 text-zinc-400 font-mono text-xs">{row[:joined_name]}</td>
                </tr>
              </tbody>
            </table>

            <div :if={@results == []} class="p-8 text-center text-zinc-500">
              No results
            </div>

            <div :if={is_nil(@results) && is_nil(@error)} class="p-8 text-center text-zinc-600">
              Write a query and press Run
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp has_joined?(results), do: Enum.any?(results, &Map.has_key?(&1, :joined_name))

  defp display_name(%{name: name, arity: arity}) when not is_nil(name) and not is_nil(arity),
    do: "#{name}/#{arity}"

  defp display_name(%{name: name}) when not is_nil(name), do: name
  defp display_name(_), do: nil

  defp kind_color(:def), do: "bg-emerald-900/60 text-emerald-300"
  defp kind_color(:defp), do: "bg-emerald-900/40 text-emerald-400"
  defp kind_color(:defmacro), do: "bg-purple-900/60 text-purple-300"
  defp kind_color(:module), do: "bg-blue-900/60 text-blue-300"
  defp kind_color(:expression), do: "bg-zinc-800 text-zinc-400"
  defp kind_color(:definition), do: "bg-amber-900/60 text-amber-300"
  defp kind_color(:reference), do: "bg-cyan-900/60 text-cyan-300"
  defp kind_color(:call), do: "bg-rose-900/60 text-rose-300"
  defp kind_color(_), do: "bg-zinc-800 text-zinc-400"
end
