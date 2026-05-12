import 'phoenix_html'
import { Socket } from 'phoenix'
import { LiveSocket } from 'phoenix_live_view'
import { Editor } from './hooks/editor'

const hooks = { Editor }
const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
const liveSocket = new LiveSocket('/live', Socket, {
  hooks,
  params: { _csrf_token: csrfToken },
  longPollFallbackMs: 2500,
})

liveSocket.connect()

if (import.meta.hot) {
  import.meta.hot.accept()
}
