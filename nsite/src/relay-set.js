// Minimal multi-relay client with hand-rolled NIP-01 frames.
//
// Why not nostr-tools' SimplePool: it sends REQ with an array of filters,
// which nos.lol rejects ("bad req: provided filter is not an object") — the
// daemon's own subscriptions use the legacy single-filter-object form for the
// same reason. Every relay accepts the object form; our queries are all
// single-filter, so we standardize on it.
//
// Reconnects with a 5s backoff and re-issues long-lived subscriptions after
// every (re)open, so the bunker inbox survives relay bounces.
//
// Mobile-Safari hardening: iOS kills sockets while the page is suspended
// (backgrounded PWA, lock screen) and the dead socket often never fires
// onclose — readyState stays OPEN while every send silently vanishes. Three
// counters: (1) a watchdog pings sockets that have been inbound-silent for a
// while and force-closes the ones that stay silent after the ping, (2) pending
// one-shot queries resolve as soon as the whole pool is dead instead of
// hanging out their full timeout, (3) revive() re-opens everything without
// waiting for the backoff when the page becomes visible again.
const RECONNECT_MS = 5000
const PING_AFTER_MS = 40000   // inbound-silent for this long -> send "ping"
const DROP_AFTER_MS = 20000   // still silent this long after the ping -> drop

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
    this.lastSeen = new Map()  // url -> ts of last inbound frame
    this.pingedAt = new Map()  // url -> ts of last unanswered watchdog ping
    this.closed = false
    this.next = 1
    if (typeof document !== 'undefined') {
      this._sweeper = setInterval(() => this._sweep(), 10000)
    }
  }

  open() { this.closed = false; this.urls.forEach((u) => this._connect(u)) }

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
    this.closed = false
    this.urls = [...new Set([...this.urls, ...(urls || []).map(normalize).filter(Boolean)])]
    this.urls.forEach((u) => this._connect(u))
  }

  // Re-open every non-live socket right now, skipping the reconnect backoff.
  // Called when the page becomes visible again — a suspended Safari page
  // comes back with dead sockets that would otherwise take a failed send to
  // notice.
  revive() {
    for (const url of this.urls) {
      const ws = this.sockets.get(url)
      if (!ws || (ws.readyState !== 0 && ws.readyState !== 1)) {
        this.sockets.delete(url)
        this._connect(url)
      }
    }
  }

  _connect(url) {
    if (this.closed || this.sockets.has(url)) return
    let ws
    try { ws = new WebSocket(url) } catch { return this._retry(url) }
    this.sockets.set(url, ws)
    this.lastSeen.set(url, Date.now())
    this.pingedAt.delete(url)
    ws.onopen = () => { this.lastSeen.set(url, Date.now()); this._resendAll(url) }
    ws.onmessage = (e) => { this.lastSeen.set(url, Date.now()); this._frame(url, String(e.data)) }
    ws.onclose = () => {
      this.sockets.delete(url)
      this.lastSeen.delete(url)
      this.pingedAt.delete(url)
      this._retry(url)
      // このソケット宛ての未決クエリを1リレー分だけ確定させ、残りは待たせる
      for (const [id, c] of this.collectors) {
        c.pending?.delete(url)
        if (c.pending && c.pending.size === 0) {
          clearTimeout(c.timer)
          this.collectors.delete(id)
          this.subs.delete(id)
          c.resolve(c.events)
        }
      }
      // Pool fully down: settle pending one-shot queries with whatever they
      // collected rather than leaving the feed staring at a spinner.
      if (![...this.sockets.values()].some((s) => s.readyState === 1)) this._flushCollectors()
    }
    ws.onerror = () => {} // onclose follows
  }

  _retry(url) {
    if (this.closed || !this.urls.includes(url) || this.sockets.has(url)) return
    setTimeout(() => { if (!this.closed && this.urls.includes(url)) this._connect(url) }, RECONNECT_MS)
  }

  _send(url, frame) {
    const ws = this.sockets.get(url)
    if (ws && ws.readyState === 1) { ws.send(JSON.stringify(frame)); return true }
    return false
  }

  _resendAll(url) {
    for (const [id, sub] of this.subs) this._send(url, ['REQ', id, sub.filter])
  }

  _flushCollectors() {
    for (const [id, c] of this.collectors) {
      clearTimeout(c.timer)
      this.collectors.delete(id)
      this.subs.delete(id)
      c.resolve(c.events)
    }
  }

  // Watchdog tick: most relays answer a plain-text "ping" with "pong" (any
  // inbound frame refreshes lastSeen), so a socket that stays silent even
  // after a ping is dead in a way Safari will not report. Force-close it and
  // let the normal onclose path reconnect + re-issue subscriptions.
  _sweep() {
    if (document.visibilityState === 'hidden') return
    const now = Date.now()
    for (const [url, ws] of this.sockets) {
      if (ws.readyState !== 1) continue
      const seen = this.lastSeen.get(url) || 0
      if (seen > (this.pingedAt.get(url) || 0)) this.pingedAt.delete(url) // answered
      if (now - seen < PING_AFTER_MS) continue
      if (!this.pingedAt.has(url)) {
        this.pingedAt.set(url, now)
        try { ws.send('ping') } catch { /* onclose follows */ }
        continue
      }
      if (now - this.pingedAt.get(url) > DROP_AFTER_MS) {
        try { ws.close() } catch { /* onclose follows */ }
      }
    }
  }

  _frame(url, data) {
    let msg
    try { msg = JSON.parse(data) } catch { return }
    const [type, id] = msg
    if (type === 'EVENT' && this.subs.has(id)) {
      this.subs.get(id).onEvent?.(msg[2])
    } else if (type === 'EOSE') {
      const c = this.collectors.get(id)
      if (c) {
        c.pending?.delete(url)
        if (!c.pending || c.pending.size === 0) {
          clearTimeout(c.timer); this.collectors.delete(id); this.subs.delete(id); c.resolve(c.events)
        }
      }
    } else if (type === 'OK') {
      const p = this.publishers.get(id)
      if (p) { clearTimeout(p.timer); this.publishers.delete(id); p.onOk(msg[2] === true) }
    } else if (type === 'CLOSED') {
      const c = this.collectors.get(id)
      if (c) {
        // 落ちたのはこのリレーだけ — 他のリレーの回答は待つ
        c.pending?.delete(url)
        if (!c.pending || c.pending.size === 0) {
          clearTimeout(c.timer); this.collectors.delete(id); this.subs.delete(id); c.resolve(c.events)
        }
      }
    }
  }

  // Long-lived subscription (bunker inbox, live feed). Re-issued on every
  // reconnect.
  subscribe(filter, onEvent) {
    const id = `bw${this.next++}`
    this.subs.set(id, { filter, onEvent })
    for (const url of this.urls) this._send(url, ['REQ', id, filter])
    return { close: () => { this.subs.delete(id); for (const url of this.urls) this._send(url, ['CLOSE', id]) } }
  }

  // One-shot query: resolves with collected events once every relay the REQ
  // reached has answered (EOSE / CLOSED / dropped) or on timeout. Per-relay
  // settling matters: a relay that REJECTS the filter (e.g. no NIP-50 search
  // support) CLOSEs immediately, and resolving the whole query on the first
  // CLOSED would truncate the other relays' results.
  query(filter, timeoutMs = 12000) {
    const id = `bw${this.next++}`
    return new Promise((resolve) => {
      const c = { events: [], resolve, timer: null, pending: new Set() }
      const settle = () => {
        clearTimeout(c.timer)
        this.collectors.delete(id)
        this.subs.delete(id)
        resolve(c.events)
      }
      c.timer = setTimeout(settle, timeoutMs)
      this.collectors.set(id, c)
      this.subs.set(id, { filter, onEvent: (ev) => c.events.push(ev) })
      for (const url of this.urls) {
        if (this._send(url, ['REQ', id, filter])) c.pending.add(url)
      }
      if (!c.pending.size) settle()
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
    this.closed = true
    for (const ws of this.sockets.values()) try { ws.close() } catch { /* gone */ }
    this.sockets.clear()
    this.subs.clear()
    this._flushCollectors()
    for (const [, p] of this.publishers) { clearTimeout(p.timer) }
    this.publishers.clear()
  }
}
