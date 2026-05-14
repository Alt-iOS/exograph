import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { Editor } from "./hooks/editor"

const RunButton = {
  mounted(this: any) {
    this.el.addEventListener("click", () => {
      const editorEl = document.querySelector("#editor") as any
      if (editorEl?._monacoEditor) {
        this.pushEvent("run", { query: editorEl._monacoEditor.getValue() })
      }
    })
  },
}

const Hooks = { Editor, RunButton }
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") ?? ""
const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken }, hooks: Hooks })
liveSocket.connect()

Object.assign(window, { liveSocket })
