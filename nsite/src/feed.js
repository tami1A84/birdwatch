// Home timeline reads — straight from the relays, no server involved.
//
// The read path follows the bunker identity's contact list (kind 3), pulls
// kind-0 profiles for labels, and renders kind-1 notes. Everything goes
// through RelaySet#query (waits for EOSE) so callers get plain arrays.
import { nip19 } from 'nostr-tools'

export const DEFAULT_READ_RELAYS = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://yabu.me',
  'wss://r.kojira.io',
]

// NIP-50 search-capable relays — the general-purpose relays above REJECT the
// `search` filter item ("bad req: unrecognised filter item", verified on
// damus/nos.lol/kojira 2026-09-06), so search queries get their own pool.
export const SEARCH_RELAYS = ['wss://nostr.wine']

export function npub(pk) {
  try { return nip19.npubEncode(pk) } catch { return pk }
}

export async function fetchContacts(relays, userPk) {
  const kind3 = await relays.query({ kinds: [3], authors: [userPk], limit: 1 })
  const latest = kind3.sort((a, b) => b.created_at - a.created_at)[0]
  if (!latest) return []
  const seen = new Set()
  return latest.tags.filter(([t]) => t === 'p')
    .map(([, pk]) => pk)
    .filter((pk) => !seen.has(pk) && seen.add(pk))
}

export async function fetchTimeline(relays, authors) {
  const filter = {
    kinds: [1], limit: 100, since: Math.floor(Date.now() / 1000) - 48 * 3600,
  }
  // authors is always the follow set (self included). There is no
  // browse/global mode since 2026-09-07 (N): an unset or empty list would
  // widen this to all authors, which the app deliberately no longer does.
  if (authors?.length) filter.authors = [...new Set(authors)].slice(0, 400)
  const notes = await relays.query(filter)
  const unique = new Map()
  for (const ev of notes.sort((a, b) => b.created_at - a.created_at)) {
    if (!unique.has(ev.id)) unique.set(ev.id, ev)
  }
  return [...unique.values()]
}

export async function fetchProfiles(relays, pks) {
  if (!pks.length) return new Map()
  const events = await relays.query({
    kinds: [0], authors: pks.slice(0, 150), limit: pks.length,
  })
  const map = new Map()
  // latest kind-0 per author wins
  for (const ev of events.sort((a, b) => a.created_at - b.created_at)) {
    let meta = {}
    try { meta = JSON.parse(ev.content) } catch { /* keep empty */ }
    map.set(ev.pubkey, meta)
  }
  return map
}

// Plain-text escape, then linkify bare URLs — the feed is user content from
// strangers' relays, so nothing is ever inserted as HTML.
export function renderContent(text) {
  const escaped = String(text)
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
  return escaped.replace(/https?:\/\/[^\s<>"')\]]+/g,
    (url) => `<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`)
}

export function timeLabel(unix) {
  const d = new Date(unix * 1000)
  const diff = (Date.now() - d.getTime()) / 1000
  if (diff < 60) return 'たった今'
  if (diff < 3600) return `${Math.floor(diff / 60)}分前`
  if (diff < 86400) return `${Math.floor(diff / 3600)}時間前`
  return d.toLocaleString('ja-JP', { year: 'numeric', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}
