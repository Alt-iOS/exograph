import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { Editor } from "./hooks/editor"

let currentEditor: any = null

const RunButton = {
  mounted(this: any) {
    this.el.addEventListener("click", () => {
      if (currentEditor) {
        this.pushEvent("run", { query: currentEditor.getValue() })
      }
    })
  },
}

const WrappedEditor = {
  ...Editor,
  async mounted(this: any) {
    await Editor.mounted.call(this)
    currentEditor = this.editor
  },
}

const Hooks = { Editor: WrappedEditor, RunButton }
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") ?? ""
const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken }, hooks: Hooks })
liveSocket.connect()

Object.assign(window, { liveSocket })
