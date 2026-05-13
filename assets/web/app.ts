import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { Editor } from "./hooks/editor"

const Hooks = { Editor }
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") ?? ""
const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken }, hooks: Hooks })
liveSocket.connect()

Object.assign(window, { liveSocket })
