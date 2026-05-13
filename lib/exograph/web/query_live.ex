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
    <div class="layout">
      <header class="header">
        <div style="display:flex;align-items:center">
          <h1>Exograph</h1>
          <span class="prefix">{@prefix}</span>
        </div>
        <div class="meta">
          <span :if={@result_count} class="stats">
            {to_string(@result_count)} results in {@elapsed_ms}ms
          </span>
          <button phx-click="run" phx-value-query={@query} class="run-btn">
            Run ⌘↵
          </button>
        </div>
      </header>

      <div class="content">
        <div class="editor-wrap">
          <div
            id="editor"
            phx-hook="Editor"
            phx-update="ignore"
            style="height:100%"
            data-query={@query}
          />
        </div>

        <div class="results-wrap">
          <div :if={@error} class="error">{@error}</div>

          <table :if={@results && @results != []}>
            <thead>
              <tr>
                <th>Kind</th>
                <th>Module</th>
                <th>Name</th>
                <th>File</th>
                <th class="right">Line</th>
                <th :if={has_joined?(@results)}>Joined</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @results}>
                <td><span class={"badge badge-" <> badge_class(row.kind)}>{to_string(row.kind)}</span></td>
                <td class="mono dim">{row.module}</td>
                <td class="mono">{display_name(row)}</td>
                <td class="dim" style="font-size:12px">{row.file}</td>
                <td class="right dim" style="font-variant-numeric:tabular-nums">{row.line}</td>
                <td :if={has_joined?(@results)} class="mono dim">{row[:joined_name]}</td>
              </tr>
            </tbody>
          </table>

          <div :if={@results == []} class="placeholder">No results</div>
          <div :if={is_nil(@results) && is_nil(@error)} class="placeholder">Write a query and press Run</div>
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

  defp badge_class(kind)
       when kind in [
              :def,
              :defp,
              :defmacro,
              :defmacrop,
              :module,
              :expression,
              :definition,
              :reference,
              :call
            ],
       do: to_string(kind)

  defp badge_class(_), do: "default"
end
