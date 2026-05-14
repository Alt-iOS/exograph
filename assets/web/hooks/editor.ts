let monaco: any = null
let completionProvider: any = null

async function loadMonaco() {
  if (!monaco) {
    const url = "/assets/vendor/monaco.js"
    monaco = await import(/* webpackIgnore: true */ url)
  }
  return monaco
}

export const Editor = {
  async mounted(this: any) {
    const m = await loadMonaco()
    const container = this.el as HTMLElement
    const query = container.dataset.query || ""

    m.editor.defineTheme("exograph", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "keyword", foreground: "c792ea" },
        { token: "string", foreground: "c3e88d" },
        { token: "number", foreground: "f78c6c" },
        { token: "comment", foreground: "546e7a", fontStyle: "italic" },
        { token: "operator", foreground: "89ddff" },
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
      language: "plaintext",
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
    })

    editor.addCommand(m.KeyMod.CtrlCmd | m.KeyCode.Enter, () => {
      this.pushEvent("run", { query: editor.getValue() })
    })

    if (completionProvider) completionProvider.dispose()
    completionProvider = m.languages.registerCompletionItemProvider("plaintext", {
      triggerCharacters: [".", ":", '"', " "],
      provideCompletionItems: (model: any, position: any) => {
        const line = model.getLineContent(position.lineNumber)
        const hint = line.slice(0, position.column - 1)
        const word = model.getWordUntilPosition(position)
        const range = new m.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn)

        return new Promise((resolve: any) => {
          const ref = String(Date.now())
          this.pushEvent("completion", { hint, ref }, (reply: any) => {
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

    this.editor = editor
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
