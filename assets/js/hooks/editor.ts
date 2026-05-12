import * as monaco from 'monaco-editor/esm/vs/editor/editor.api'
import 'monaco-editor/esm/vs/basic-languages/elixir/elixir.contribution'

const DARK_THEME: monaco.editor.IStandaloneThemeData = {
  base: 'vs-dark',
  inherit: true,
  rules: [
    { token: 'keyword', foreground: 'c792ea' },
    { token: 'string', foreground: 'c3e88d' },
    { token: 'number', foreground: 'f78c6c' },
    { token: 'comment', foreground: '546e7a', fontStyle: 'italic' },
    { token: 'atom', foreground: '82aaff' },
    { token: 'operator', foreground: '89ddff' },
    { token: 'module', foreground: 'ffcb6b' },
    { token: 'function', foreground: '82aaff' },
  ],
  colors: {
    'editor.background': '#09090b',
    'editor.foreground': '#e4e4e7',
    'editor.lineHighlightBackground': '#18181b',
    'editor.selectionBackground': '#27272a',
    'editorCursor.foreground': '#3b82f6',
    'editorWidget.background': '#18181b',
    'editorWidget.border': '#27272a',
    'editorSuggestWidget.background': '#18181b',
    'editorSuggestWidget.border': '#27272a',
    'editorSuggestWidget.selectedBackground': '#27272a',
    'list.hoverBackground': '#27272a',
  },
}

monaco.editor.defineTheme('exograph-dark', DARK_THEME)

let completionProvider: monaco.IDisposable | null = null

export const Editor = {
  mounted(this: any) {
    const container = this.el as HTMLElement
    const query = container.dataset.query || ''

    const editor = monaco.editor.create(container, {
      value: query,
      language: 'elixir',
      theme: 'exograph-dark',
      fontFamily: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace',
      fontSize: 13,
      lineHeight: 20,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      overviewRulerLanes: 0,
      renderLineHighlight: 'line',
      padding: { top: 12, bottom: 12 },
      suggestSelection: 'first',
      quickSuggestions: { other: true, strings: true, comments: false },
      tabSize: 2,
      wordWrap: 'on',
      automaticLayout: true,
    })

    // Ctrl/Cmd+Enter to run
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => {
      this.pushEvent('run', { query: editor.getValue() })
    })

    // Completion provider
    if (completionProvider) completionProvider.dispose()

    completionProvider = monaco.languages.registerCompletionItemProvider('elixir', {
      triggerCharacters: ['.', ':', '"', ' '],
      provideCompletionItems: (model, position) => {
        const line = model.getLineContent(position.lineNumber)
        const hint = line.slice(0, position.column - 1)
        const word = model.getWordUntilPosition(position)
        const range = new monaco.Range(
          position.lineNumber,
          word.startColumn,
          position.lineNumber,
          word.endColumn,
        )

        return new Promise((resolve) => {
          const ref = String(Date.now())

          this.pushEvent('completion', { hint, ref }, (reply: any) => {
            const suggestions = (reply.items || []).map((item: any) => ({
              label: item.label,
              kind: mapKind(item.kind),
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
    if (this.editor) {
      this.editor.dispose()
    }
    if (completionProvider) {
      completionProvider.dispose()
      completionProvider = null
    }
  },
}

function mapKind(kind: string): monaco.languages.CompletionItemKind {
  switch (kind) {
    case 'module':
      return monaco.languages.CompletionItemKind.Module
    case 'function':
      return monaco.languages.CompletionItemKind.Function
    case 'field':
      return monaco.languages.CompletionItemKind.Field
    case 'variable':
      return monaco.languages.CompletionItemKind.Variable
    default:
      return monaco.languages.CompletionItemKind.Text
  }
}
