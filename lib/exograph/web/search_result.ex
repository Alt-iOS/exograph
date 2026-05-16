defmodule Exograph.Web.SearchResult do
  @moduledoc false

  defstruct [
    :type,
    :file,
    :package,
    :module,
    :kind,
    :name,
    :arity,
    :line,
    :source,
    :fragment_line,
    :joined_label,
    :preview,
    :package_version
  ]

  def from(%Exograph.Hit{fragment: f, match: m}) do
    %__MODULE__{
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
      joined_label: nil,
      preview: nil,
      package_version: extract_package_version(f.file)
    }
  end

  def from(%Exograph.TextHit{fragment: f}) do
    %__MODULE__{
      type: :text,
      file: relative_path(f.file),
      package: extract_package(f.file),
      module: f.module,
      kind: f.kind,
      name: f.name,
      arity: f.arity,
      line: f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: nil,
      preview: nil,
      package_version: extract_package_version(f.file)
    }
  end

  def from({%Exograph.Hit{fragment: f, match: m}, joined}) do
    %__MODULE__{
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
      joined_label: format_joined(joined),
      preview: nil,
      package_version: extract_package_version(f.file)
    }
  end

  def from({%Exograph.Hit{} = hit, j1, j2}) do
    result = from({hit, j1})

    joined =
      [result.joined_label, inspect(j2, limit: 60)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    %{result | joined_label: joined}
  end

  def from({%Exograph.Hit{} = hit, j1, j2, j3}) do
    result = from({hit, j1})

    joined =
      [result.joined_label, inspect(j2, limit: 40), inspect(j3, limit: 40)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    %{result | joined_label: joined}
  end

  def from(%Exograph.DefinitionHit{definition: d, fragment: f}) do
    file = if f, do: f.file || "", else: ""

    %__MODULE__{
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
      joined_label: nil,
      preview: nil,
      package_version: extract_package_version(file)
    }
  end

  def from(%Exograph.ReferenceHit{reference: r, fragment: f}) do
    file = if f, do: f.file || "", else: ""

    %__MODULE__{
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
      joined_label: nil,
      preview: nil,
      package_version: extract_package_version(file)
    }
  end

  def from(%Exograph.CallEdgeHit{call_edge: e}) do
    %__MODULE__{
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
      joined_label: nil,
      preview: nil,
      package_version: nil
    }
  end

  def from(tuple) when is_tuple(tuple) do
    case Tuple.to_list(tuple) do
      [%Exograph.Hit{} = hit | rest] -> from({hit, List.first(rest)})
      _ -> unknown_result(inspect(tuple, limit: 200))
    end
  end

  def from(other), do: unknown_result(inspect(other, limit: 200))

  defp unknown_result(label) do
    %__MODULE__{
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
      joined_label: nil,
      preview: nil,
      package_version: nil
    }
  end

  defp format_joined(%Exograph.Definition{} = d), do: "def #{d.qualified_name}"
  defp format_joined(%Exograph.Reference{} = r), do: "ref #{r.qualified_name}"

  defp format_joined(%Exograph.CallEdge{} = e),
    do: "#{e.caller_qualified_name} → #{e.callee_qualified_name}"

  defp format_joined(_), do: nil

  defp match_line(nil), do: nil
  defp match_line(%{line: line}), do: line
  defp match_line(%{node: {_, meta, _}}) when is_list(meta), do: Keyword.get(meta, :line)
  defp match_line(_), do: nil

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

  defp extract_package_version(nil), do: nil
  defp extract_package_version(""), do: nil

  defp extract_package_version(file) do
    case Regex.run(~r"/sources/([^/]+)/", file) do
      [_, pkg_dir] ->
        case Regex.run(~r/^.+-(\d+\.\d+\.\d+.*)$/, pkg_dir) do
          [_, version] -> version
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
