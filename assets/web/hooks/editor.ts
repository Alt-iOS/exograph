let completionProvider: any = null

async function loadMonaco() {
  const url = "/assets/vendor/monaco.js"
  return await import(/* webpackIgnore: true */ url)
}

const ELIXIR_LANGUAGE = "elixir"

function registerElixirLanguage(m: any) {
  if (m.languages.getLanguages().some((l: any) => l.id === ELIXIR_LANGUAGE)) return

  m.languages.register({ id: ELIXIR_LANGUAGE })
  m.languages.setLanguageConfiguration(ELIXIR_LANGUAGE, {
    comments: { lineComment: "#" },
    brackets: [["(", ")"], ["[", "]"], ["{", "}"], ["do", "end"]],
    autoClosingPairs: [
      { open: "(", close: ")" },
      { open: "[", close: "]" },
      { open: "{", close: "}" },
      { open: '"', close: '"' },
      { open: "'", close: "'" },
    ],
    surroundingPairs: [
      { open: "(", close: ")" },
      { open: "[", close: "]" },
      { open: "{", close: "}" },
      { open: '"', close: '"' },
      { open: "'", close: "'" },
    ],
    indentationRules: {
      increaseIndentPattern: /^\s*(def|defp|defmodule|defmacro|defmacrop|if|unless|case|cond|fn|do|else|with|for|receive|try|catch|rescue|after)\b.*$/,
      decreaseIndentPattern: /^\s*(end|else|catch|rescue|after)\b/,
    },
  })
  m.languages.setMonarchTokensProvider(ELIXIR_LANGUAGE, {
    keywords: [
      "def", "defp", "defmodule", "defmacro", "defmacrop", "defstruct", "defprotocol",
      "defimpl", "defguard", "defdelegate", "defexception", "defoverridable",
      "do", "end", "fn", "case", "cond", "if", "else", "unless", "when",
      "with", "for", "receive", "try", "catch", "rescue", "after", "raise",
      "throw", "import", "require", "alias", "use", "quote", "unquote",
      "in", "not", "and", "or", "true", "false", "nil",
    ],
    operators: [
      "=", ">", "<", "!", "~", "?", ":", "==", "<=", ">=", "!=",
      "&&", "||", "++", "--", "<>", "->", "|>", "::", "..", "=~",
      "===", "!==", "<<<", ">>>",
    ],
    tokenizer: {
      root: [
        [/#.*$/, "comment"],
        [/@\w+/, "annotation"],
        [/:[a-zA-Z_]\w*/, "atom"],
        [/"/, "string", "@string_double"],
        [/'/, "string", "@string_single"],
        [/~[a-zA-Z]"""/, "string", "@heredoc"],
        [/~[a-zA-Z]"/, "string", "@sigil_double"],
        [/\d[\d_]*(\.\d[\d_]*)?(e[+-]?\d+)?/, "number"],
        [/0[xXoObB][\da-fA-F_]+/, "number"],
        [/[A-Z][\w.]*/, "type"],
        [/[a-z_]\w*[?!]?/, { cases: { "@keywords": "keyword", "@default": "identifier" } }],
        [/[{}()\[\]]/, "@brackets"],
        [/[<>]=?|[!=]=?|&&?|\|\|?|\+\+?|--?|<>|\|>|->|::|\.\.|=~/, "operator"],
        [/[;,.]/, "delimiter"],
      ],
      string_double: [
        [/#\{/, "string.interpolation", "@interpolation"],
        [/[^"#]+/, "string"],
        [/"/, "string", "@pop"],
      ],
      string_single: [
        [/[^']+/, "string"],
        [/'/, "string", "@pop"],
      ],
      heredoc: [
        [/#\{/, "string.interpolation", "@interpolation"],
        [/"""/, "string", "@pop"],
        [/./, "string"],
      ],
      sigil_double: [
        [/#\{/, "string.interpolation", "@interpolation"],
        [/"/, "string", "@pop"],
        [/./, "string"],
      ],
      interpolation: [
        [/\}/, "string.interpolation", "@pop"],
        { include: "root" },
      ],
    },
  })
}

export const Editor = {
  async mounted(this: any) {
    const hook = this
    const container = this.el as HTMLElement
    const query = container.dataset.query || ""
    const m = await loadMonaco()

    registerElixirLanguage(m)

    m.editor.defineTheme("exograph", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "keyword", foreground: "c792ea" },
        { token: "type", foreground: "ffcb6b" },
        { token: "atom", foreground: "82aaff" },
        { token: "string", foreground: "c3e88d" },
        { token: "string.interpolation", foreground: "89ddff" },
        { token: "number", foreground: "f78c6c" },
        { token: "comment", foreground: "546e7a", fontStyle: "italic" },
        { token: "operator", foreground: "89ddff" },
        { token: "annotation", foreground: "f07178" },
        { token: "identifier", foreground: "eeffff" },
        { token: "delimiter", foreground: "89ddff" },
      ],
      colors: {
        "editor.background": "#09090b",
        "editor.foreground": "#f4f4f5",
        "editor.lineHighlightBackground": "#18181b",
        "editor.selectionBackground": "#27272a",
        "editorCursor.foreground": "#3b82f6",
        "editorWidget.background": "#18181b",
        "editorWidget.border": "#27272a",
        "editorSuggestWidget.background": "#18181b",
        "editorSuggestWidget.border": "#27272a",
        "editorSuggestWidget.selectedBackground": "#27272a",
        "list.hoverBackground": "#27272a",
      },
    })

    const editor = m.editor.create(container, {
      value: query,
      language: ELIXIR_LANGUAGE,
      theme: "exograph",
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: 13,
      lineHeight: 20,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      overviewRulerLanes: 0,
      renderLineHighlight: "line",
      padding: { top: 12, bottom: 12 },
      tabSize: 2,
      wordWrap: "on",
      automaticLayout: true,
      quickSuggestions: true,
      suggestOnTriggerCharacters: true,
    })

    editor.addCommand(m.KeyMod.CtrlCmd | m.KeyCode.Enter, () => {
      hook.pushEvent("run", { query: editor.getValue() })
    })

    if (completionProvider) completionProvider.dispose()
    completionProvider = m.languages.registerCompletionItemProvider(ELIXIR_LANGUAGE, {
      triggerCharacters: [".", ":", '"', " "],
      provideCompletionItems: (model: any, position: any) => {
        const line = model.getLineContent(position.lineNumber)
        const hint = line.slice(0, position.column - 1)
        const word = model.getWordUntilPosition(position)
        const range = new m.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn)

        return new Promise((resolve: any) => {
          hook.pushEvent("completion", { hint }, (reply: any) => {
            const suggestions = (reply.items || []).map((item: any) => ({
              label: item.label,
              kind: mapKind(m, item.kind),
              detail: item.detail,
              insertText: item.insert_text,
              range,
            }))
            resolve({ suggestions })
          })
        })
      },
    })

    hook.handleEvent("set_editor_value", ({ value }: { value: string }) => {
      editor.setValue(value)
      editor.focus()
    })

    hook.handleEvent("set_diagnostics", ({ markers }: { markers: any[] }) => {
      const model = editor.getModel()
      if (!model) return
      m.editor.setModelMarkers(model, "exograph", markers.map((mk: any) => ({
        severity: m.MarkerSeverity.Error,
        message: mk.message,
        startLineNumber: mk.line || 1,
        startColumn: mk.column || 1,
        endLineNumber: mk.end_line || mk.line || 1,
        endColumn: mk.end_column || 1000,
      })))
    })

    container.addEventListener("keydown", (e: KeyboardEvent) => e.stopPropagation())

    this.editor = editor
    ;(container as any)._monacoEditor = editor
  },

  destroyed(this: any) {
    if (this.editor) this.editor.dispose()
    if (completionProvider) { completionProvider.dispose(); completionProvider = null }
  },
}

function mapKind(m: any, kind: string) {
  switch (kind) {
    case "module": return m.languages.CompletionItemKind.Module
    case "function": return m.languages.CompletionItemKind.Function
    case "field": return m.languages.CompletionItemKind.Field
    case "variable": return m.languages.CompletionItemKind.Variable
    default: return m.languages.CompletionItemKind.Text
  }
}
