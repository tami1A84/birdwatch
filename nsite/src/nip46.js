// NIP-46 bunker client — birdwatch static app.
//
// The daemon is the remote signer; this browser acts as the NIP-46 client
// with an ephemeral key kept in localStorage. Requests travel as kind-24133
// events (NIP-44 v2 encrypted) over the relays advertised in the bunker
// URI; responses come back on our own p-tag subscription.
import { finalizeEvent, nip44, getPublicKey } from 'nostr-tools'
import { RelaySet } from './relay-set.js'

export function parseBunkerUri(uri) {
  const m = /^bunker:\/\/([0-9a-f]{64})(\?.*)$/.exec((uri || '').trim())
  if (!m) throw new Error('bunker URIの形式が違います (bunker://<pubkey>?relay=…&secret=…)')
  const q = new URLSearchParams(m[2])
  const relays = q.getAll('relay')
  const secret = q.get('secret')
  if (!relays.length) throw new Error('bunker URIにリレーがありません')
  if (!secret) throw new Error('bunker URIにsecretがありません')
  return { pubkey: m[1], relays, secret }
}

// Requests time out generously: relay round trips through 2-4 hops can be
// slow, and the daemon answers every method (even errors) with a response.
const REQUEST_TIMEOUT_MS = 30000

// Errors don't settle a request immediately: another NIP-46 responder that
// does NOT hold the current secret may share the signer pubkey on the relays
// and answer faster with a misleading error (observed 2026-09-06: a
// non-nostrd signer replied flat "invalid secret" ~1s before the real
// daemon's response). Wait ERROR_GRACE_MS for a success; if none comes,
// reject with the most authoritative error seen (structured beats flat).
const ERROR_GRACE_MS = 12000

export class BunkerClient {
  constructor(relays = null) {
    this.relays = relays || new RelaySet([])
    this.inbox = null
    this.pending = new Map()
    this.daemonPk = null
  }

  get connected() { return !!this.daemonPk }

  // sk: Uint8Array ephemeral secret key (persisted by the caller).
  async connect(uri, sk, onStatus = () => {}) {
    try {
      return await this._connect(uri, sk, onStatus)
    } catch (e) {
      // No half-connected state: a failed handshake must leave the client
      // actually disconnected (and must not leak the inbox subscription).
      this.close()
      throw e
    }
  }

  async _connect(uri, sk, onStatus = () => {}) {
    this.close()
    const parsed = parseBunkerUri(uri)
    this.sk = sk
    this.pk = getPublicKey(sk)
    this.daemonPk = parsed.pubkey
    this.conversationKey = nip44.v2.utils.getConversationKey(sk, parsed.pubkey)

    this.relays.addUrls(parsed.relays)
    onStatus(`リレーに接続中 (${this.relays.urls.length}台)…`)
    // Our inbox: NIP-46 responses addressed to the ephemeral pubkey. `since`
    // guards against replays of ancient responses; the daemon replies to the
    // request id we generate, so a fresh id never matches old traffic.
    this.inbox = this.relays.subscribe(
      { kinds: [24133], '#p': [this.pk], since: Math.floor(Date.now() / 1000) - 60 },
      (ev) => this.onResponse(ev))

    const result = await this.request('connect', [parsed.pubkey, parsed.secret])
    if (result !== 'ack') throw new Error(`connect: unexpected result ${JSON.stringify(result)}`)
    return this.request('get_public_key', [])
  }

  onResponse(ev) {
    let msg
    try {
      const senderKey = nip44.v2.utils.getConversationKey(this.sk, ev.pubkey)
      msg = JSON.parse(nip44.v2.decrypt(ev.content, senderKey))
    } catch {
      return // not for us / undecryptable — ignore quietly
    }
    const pending = this.pending.get(msg.id)
    if (!pending) return
    if (msg.error) {
      // Prefer structured errors ({code,message}) over flat strings — the
      // real daemon's error arrives as an object; shadow signers answer
      // with strings. First structured error wins; strings only fill the gap.
      if (!pending.error || (typeof pending.error === 'string' && typeof msg.error !== 'string')) {
        pending.error = msg.error
      }
      if (!pending.errorTimer) {
        pending.errorTimer = setTimeout(() => {
          clearTimeout(pending.timer)
          this.pending.delete(msg.id)
          const err = pending.error
          pending.reject(new Error(typeof err === 'string' ? err : (err?.message || 'リクエスト失敗')))
        }, ERROR_GRACE_MS)
      }
      return
    }
    clearTimeout(pending.timer)
    if (pending.errorTimer) clearTimeout(pending.errorTimer)
    this.pending.delete(msg.id)
    pending.resolve(msg.result)
  }

  request(method, params) {
    if (!this.daemonPk) return Promise.reject(new Error('bunker未接続'))
    const id = crypto.randomUUID()
    const p = new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.pending.get(id).timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method}: タイムアウト(${REQUEST_TIMEOUT_MS / 1000}s)`))
      }, REQUEST_TIMEOUT_MS)
    })
    this._sendRequest(method, params, id)
    return p
  }

  async _sendRequest(method, params, id) {
    // The relay pool opens lazily; wait for a live socket or the request
    // would be dropped before any relay could see it.
    await this.relays.ready(6000)
    const pending = this.pending.get(id)
    if (!pending) return // already timed out
    const payload = JSON.stringify({ id, method, params })
    const content = nip44.v2.encrypt(payload, this.conversationKey)
    const req = finalizeEvent(
      { kind: 24133, created_at: Math.floor(Date.now() / 1000), tags: [['p', this.daemonPk]], content },
      this.sk)
    // At least one relay accepting the event is enough; the daemon listens
    // on the same set and answers via our inbox subscription.
    this.relays.publish(req).catch(() => {})
  }

  async signEvent(event) {
    const json = await this.request('sign_event', [JSON.stringify(event)])
    const signed = typeof json === 'string' ? JSON.parse(json) : json
    if (!signed || !signed.sig || !signed.id) throw new Error('署名応答が不正です')
    return signed
  }

  close() {
    if (this.inbox) try { this.inbox.close() } catch { /* already gone */ }
    this.inbox = null
    this.daemonPk = null
    for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(new Error('bunker切断')) }
    this.pending.clear()
  }
}
