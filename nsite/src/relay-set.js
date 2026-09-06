// Minimal multi-relay client with hand-rolled NIP-01 frames.
//
// Why not nostr-tools' SimplePool: it sends REQ with an array of filters,
// which nos.lol rejects ("bad req: provided filter is not an object") — the
// daemon's own subscriptions use the legacy single-filter-object form for
// the same reason. Every relay accepts the object form; our queries are all
// single-filter, so we standardize on it.
//
// Reconnects with a 5s backoff and re-issues long-lived subscriptions after
// every (re)open, so the bunker inbox survives relay bounces.
const RECONNECT_MS = 5000

function normalize(url) {
  let u = url.trim()
  if (!/^wss?:\/\//.test(u)) u = `wss://${u}`
  return u.replace(/\/+$/, '')
}

export class RelaySet {
  constructor(urls) {
    this.urls = [...new Set((urls || []).map(normalize).filter(Boolean))]
    this.sockets = new Map()   // url -> WebSocket
    this.subs = new Map()      // id -> { filter, onEvent, persist }
    this.collectors = new Map() // id -> { events, resolve, timer }
    this.publishers = new Map() // id -> { accept, timer }
    this.next = 1
  }

  open() { this.urls.forEach((u) => this._connect(u)) }

  // Resolves as soon as any socket is open (or after the cap, so callers
  // can proceed and let publish() report the failure instead of hanging).
  ready(timeoutMs = 8000) {
    if ([...this.sockets.values()].some((ws) => ws.readyState === 1)) return Promise.resolve()
    return new Promise((resolve) => {
      const t = setTimeout(resolve, timeoutMs)
      const iv = setInterval(() => {
        if ([...this.sockets.values()].some((ws) => ws.readyState === 1)) {
          clearInterval(iv); clearTimeout(t); resolve()
        }
      }, 100)
    })
  }

  // Merge in more relays (e.g. the ones advertised in a bunker URI) and
  // connect to the newcomers.
  addUrls(urls) {
    this.urls = [...new Set([...this.urls, ...(urls || []).map(normalize).filter(Boolean)])]
    this.urls.forEach((u) => this._connect(u))
  }

  _connect(url) {
    if (this.sockets.has(url)) return
    let ws
    try { ws = new WebSocket(url) } catch { return this._retry(url) }
    this.sockets.set(url, ws)
    ws.onopen = () => this._resendAll(url)
    ws.onmessage = (e) => this._frame(url, String(e.data))
    ws.onclose = () => { this.sockets.delete(url); this._retry(url) }
    ws.onerror = () => {} // onclose follows
  }

  _retry(url) {
    if (!this.urls.includes(url) || this.sockets.has(url)) return
    setTimeout(() => { if (this.urls.includes(url)) this._connect(url) }, RECONNECT_MS)
  }

  _send(url, frame) {
    const ws = this.sockets.get(url)
    if (ws && ws.readyState === 1) { ws.send(JSON.stringify(frame)); return true }
    return false
  }

  _resendAll(url) {
    for (const [id, sub] of this.subs) this._send(url, ['REQ', id, sub.filter])
  }

  _frame(url, data) {
    let msg
    try { msg = JSON.parse(data) } catch { return }
    const [type, id] = msg
    if (type === 'EVENT' && this.subs.has(id)) {
      this.subs.get(id).onEvent?.(msg[2])
    } else if (type === 'EOSE') {
      const c = this.collectors.get(id)
      if (c) { clearTimeout(c.timer); this.collectors.delete(id); c.resolve(c.events) }
    } else if (type === 'OK') {
      const p = this.publishers.get(id)
      if (p) { clearTimeout(p.timer); this.publishers.delete(id); p.onOk(msg[2] === true) }
    } else if (type === 'CLOSED') {
      const c = this.collectors.get(id)
      if (c) { clearTimeout(c.timer); this.collectors.delete(id); c.resolve(c.events) }
    }
  }

  // Long-lived subscription (bunker inbox). Re-issued on every reconnect.
  subscribe(filter, onEvent) {
    const id = `bw${this.next++}`
    this.subs.set(id, { filter, onEvent })
    for (const url of this.urls) this._send(url, ['REQ', id, filter])
    return { close: () => { this.subs.delete(id); for (const url of this.urls) this._send(url, ['CLOSE', id]) } }
  }

  // One-shot query: resolves with collected events on EOSE (or timeout).
  query(filter, timeoutMs = 12000) {
    const id = `bw${this.next++}`
    return new Promise((resolve) => {
      const c = { events: [], resolve, timer: null }
      c.timer = setTimeout(() => { this.collectors.delete(id); resolve(c.events) }, timeoutMs)
      this.collectors.set(id, c)
      this.subs.set(id, { filter, onEvent: (ev) => c.events.push(ev) })
      for (const url of this.urls) this._send(url, ['REQ', id, filter])
      setTimeout(() => { if (this.collectors.has(id)) { this.subs.delete(id); for (const url of this.urls) this._send(url, ['CLOSE', id]) } }, timeoutMs + 500)
    })
  }

  // EVENT frame; resolves once at least one relay OKs it (or on timeout).
  publish(event, timeoutMs = 10000) {
    const id = event.id
    return new Promise((resolve) => {
      let accepted = 0
      const finish = () => {
        clearTimeout(timer)
        this.publishers.delete(id)
        resolve({ accepted, ok: accepted > 0 })
      }
      const timer = setTimeout(finish, timeoutMs)
      this.publishers.set(id, {
        onOk: (ok) => { if (ok) { accepted++; finish() } },
      })
      for (const url of this.urls) this._send(url, ['EVENT', event])
    })
  }

  close() {
    for (const ws of this.sockets.values()) try { ws.close() } catch { /* gone */ }
    this.sockets.clear()
    this.subs.clear()
  }
}
