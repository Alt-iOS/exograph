defmodule Exograph.Web.QueryLive do
  @moduledoc false

  use Exograph.Web, :live_view

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
  def handle_event("completion", %{"hint" => hint}, socket) do
    items = Exograph.Web.Completion.complete(hint, socket.assigns.index)
    {:reply, %{items: items}, socket}
  end

  defp execute_query(index, query_string) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        try do
          {parsed, _bindings} = Code.eval_string(query_string, [], eval_env())
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

  defp eval_env do
    import Exograph.DSL
    __ENV__
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
    results
    |> Enum.map(&normalize_result/1)
    |> Enum.group_by(& &1.package)
    |> Enum.sort_by(fn {pkg, _} -> pkg end)
    |> Enum.map(fn {package, pkg_results} ->
      files =
        pkg_results
        |> Enum.group_by(& &1.file)
        |> Enum.sort_by(fn {file, _} -> file end)
        |> Enum.map(fn {file, file_results} ->
          %{
            file: file,
            results:
              Enum.map(file_results, fn r ->
                Map.put(r, :preview, build_preview(r.source, r.fragment_line, r.line))
              end)
          }
        end)

      %{package: package, count: length(pkg_results), files: files}
    end)
  end

  defp normalize_result(%Exograph.Hit{fragment: f, match: m}) do
    %{
      type: :fragment,
      file: relative_path(f.file),
      package: extract_package(f.file),
      module: f.module,
      kind: f.kind,
      name: f.name,
      arity: f.arity,
      line: match_line(m) || f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: nil
    }
  end

  defp normalize_result({%Exograph.Hit{fragment: f, match: m}, joined}) do
    %{
      type: :joined,
      file: relative_path(f.file),
      package: extract_package(f.file),
      module: f.module,
      kind: f.kind,
      name: f.name,
      arity: f.arity,
      line: match_line(m) || f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: format_joined(joined)
    }
  end

  defp normalize_result({%Exograph.Hit{} = hit, j1, j2}) do
    normalize_result({hit, j1})
    |> Map.update(:joined_label, nil, fn lbl ->
      [lbl, inspect(j2, limit: 60)] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    end)
  end

  defp normalize_result({%Exograph.Hit{} = hit, j1, j2, j3}) do
    normalize_result({hit, j1})
    |> Map.update(:joined_label, nil, fn lbl ->
      [lbl, inspect(j2, limit: 40), inspect(j3, limit: 40)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
    end)
  end

  defp normalize_result(%Exograph.DefinitionHit{definition: d, fragment: f}) do
    file = if f, do: f.file || "", else: ""

    %{
      type: :definition,
      file: file,
      package: extract_package(file),
      module: d.module,
      kind: d.kind,
      name: d.qualified_name,
      arity: d.arity,
      line: d.line,
      source: if(f, do: f.source, else: nil),
      fragment_line: if(f, do: f.line, else: nil),
      joined_label: nil
    }
  end

  defp normalize_result(%Exograph.ReferenceHit{reference: r, fragment: f}) do
    file = if f, do: f.file || "", else: ""

    %{
      type: :reference,
      file: file,
      package: extract_package(file),
      module: r.module,
      kind: r.kind,
      name: r.qualified_name,
      arity: r.arity,
      line: r.line,
      source: if(f, do: f.source, else: nil),
      fragment_line: if(f, do: f.line, else: nil),
      joined_label: nil
    }
  end

  defp normalize_result(%Exograph.CallEdgeHit{call_edge: e}) do
    %{
      type: :call_edge,
      file: "",
      package: "call_edges",
      module: nil,
      kind: :call,
      name: "#{e.caller_qualified_name} → #{e.callee_qualified_name}",
      arity: nil,
      line: e.line,
      source: nil,
      fragment_line: nil,
      joined_label: nil
    }
  end

  defp normalize_result(tuple) when is_tuple(tuple) do
    case Tuple.to_list(tuple) do
      [%Exograph.Hit{} = hit | rest] -> normalize_result({hit, List.first(rest)})
      _ -> unknown_result(inspect(tuple, limit: 200))
    end
  end

  defp normalize_result(other), do: unknown_result(inspect(other, limit: 200))

  defp unknown_result(label) do
    %{
      type: :unknown,
      file: "",
      package: "unknown",
      module: nil,
      kind: nil,
      name: label,
      arity: nil,
      line: nil,
      source: nil,
      fragment_line: nil,
      joined_label: nil
    }
  end

  defp format_joined(%Exograph.Definition{} = d), do: "def #{d.qualified_name}"
  defp format_joined(%Exograph.Reference{} = r), do: "ref #{r.qualified_name}"

  defp format_joined(%Exograph.CallEdge{} = e),
    do: "#{e.caller_qualified_name} → #{e.callee_qualified_name}"

  defp format_joined(_), do: nil

  defp relative_path(nil), do: ""

  defp relative_path(path) do
    case Regex.run(~r"/sources/[^/]+/(.+)$", path) do
      [_, rel] -> rel
      _ -> Path.basename(path)
    end
  end

  defp extract_package(nil), do: "unknown"
  defp extract_package(""), do: "unknown"

  defp extract_package(file) do
    case Regex.run(~r"/sources/([^/]+)/", file) do
      [_, pkg_dir] ->
        case Regex.run(~r/^(.+)-\d/, pkg_dir) do
          [_, name] -> name
          _ -> pkg_dir
        end

      _ ->
        file |> Path.basename() |> Path.rootname()
    end
  end

  defp build_preview(nil, _, _), do: nil
  defp build_preview(_, _, nil), do: nil

  defp build_preview(source, fragment_line, match_line)
       when is_binary(source) and is_integer(match_line) do
    fline = if is_integer(fragment_line), do: fragment_line, else: 1
    relative = max(match_line - fline + 1, 1)

    source
    |> Exograph.Web.Highlighter.highlight(relative, 2)
    |> Enum.map(fn {rel_num, html, is_matched} ->
      {rel_num + fline - 1, html, is_matched}
    end)
  end

  defp build_preview(_, _, _), do: nil

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
            {@result_count} results across {length(@results || [])} packages in {@elapsed_ms}ms
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
                  <svg
                    class="w-3.5 h-3.5 text-zinc-500 flex-shrink-0"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                    />
                  </svg>
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

                    <div :if={result.preview} class="rounded border border-zinc-800 overflow-hidden">
                      <div
                        :for={{line_num, html, is_matched} <- result.preview}
                        class={"flex items-stretch font-mono text-xs" <> if(is_matched, do: " bg-blue-900/20 border-l-2 border-l-blue-500", else: "")}
                      >
                        <span class="w-10 text-right pr-3 py-1 text-zinc-600 select-none flex-shrink-0 bg-zinc-900/50 border-r border-zinc-800/50 tabular-nums leading-5">
                          {line_num}
                        </span>
                        <code class="py-1 px-3 flex-1 overflow-x-hidden text-zinc-300 leading-5 whitespace-pre">
                          {raw(html)}
                        </code>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div :if={@results == []} class="p-8 text-center text-zinc-500">No results</div>
          <div :if={is_nil(@results) && is_nil(@error)} class="p-8 text-center text-zinc-600">
            Write a query and press Run
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp display_name(%{name: name, arity: arity}) when not is_nil(name) and not is_nil(arity),
    do: "#{name}/#{arity}"

  defp display_name(%{name: name}) when not is_nil(name), do: name
  defp display_name(_), do: nil

  defp match_line(nil), do: nil
  defp match_line(%{line: line}), do: line
  defp match_line(%{node: {_, meta, _}}) when is_list(meta), do: Keyword.get(meta, :line)
  defp match_line(_), do: nil

  defp badge_class(:def), do: "bg-blue-900/40 text-blue-300"
  defp badge_class(:defp), do: "bg-zinc-800 text-zinc-400"
  defp badge_class(:defmacro), do: "bg-purple-900/40 text-purple-300"
  defp badge_class(:defmacrop), do: "bg-purple-900/30 text-purple-400"
  defp badge_class(:module), do: "bg-yellow-900/40 text-yellow-300"
  defp badge_class(:expression), do: "bg-green-900/40 text-green-300"
  defp badge_class(:definition), do: "bg-indigo-900/40 text-indigo-300"
  defp badge_class(:reference), do: "bg-orange-900/40 text-orange-300"
  defp badge_class(:call), do: "bg-teal-900/40 text-teal-300"
  defp badge_class(_), do: "bg-zinc-800 text-zinc-400"
end
