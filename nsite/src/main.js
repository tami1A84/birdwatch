// birdwatch static app — browser-side wiring.
//
// Reads: home timeline straight from relays (feed.js). Writes: NIP-46 via
// the user's daemon bunker (nip46.js) — the browser never holds the
// identity key, only an ephemeral client key in localStorage.
import { RelaySet } from './relay-set.js'
import { generateSecretKey, getPublicKey } from 'nostr-tools'
import { BunkerClient, parseBunkerUri } from './nip46.js'
import { DEFAULT_READ_RELAYS, fetchContacts, fetchTimeline, fetchProfiles,
         renderContent, timeLabel, npub } from './feed.js'

const SK_KEY = 'bw_ephem_sk'
const URI_KEY = 'bw_bunker_uri'

const $ = (id) => document.getElementById(id)
const relays = new RelaySet(DEFAULT_READ_RELAYS)
const bunker = new BunkerClient(relays)

let userPk = null
let contacts = []
let profiles = new Map()
let readRelays = [...DEFAULT_READ_RELAYS]

function ephemeralKey() {
  const stored = localStorage.getItem(SK_KEY)
  if (stored) {
    const sk = Uint8Array.from(stored.match(/.{2}/g).map((h) => parseInt(h, 16)))
    return sk
  }
  const sk = generateSecretKey()
  localStorage.setItem(SK_KEY, [...sk].map((b) => b.toString(16).padStart(2, '0')).join(''))
  return sk
}

function status(text, ok = null) {
  const el = $('conn-status')
  el.textContent = text
  el.dataset.state = ok === null ? 'busy' : ok ? 'ok' : 'err'
}

async function connectStored(onDone = () => {}) {
  const uri = localStorage.getItem(URI_KEY)
  if (!uri) return false
  try {
    const parsed = parseBunkerUri(uri)
    readRelays = [...new Set([...parsed.relays, ...DEFAULT_READ_RELAYS])]
    userPk = await bunker.connect(uri, ephemeralKey(), status)
    status(`接続済み — ${npub(userPk).slice(0, 12)}…`, true)
    $('bunker-uri').value = uri
    $('btn-disconnect').hidden = false
    onDone()
    return true
  } catch (e) {
    status(`接続失敗: ${e.message}`, false)
    return false
  }
}

async function connectNew() {
  const uri = $('bunker-uri').value.trim()
  if (!uri) { status('bunker URIを貼り付けてください', false); return }
  bunker.close()
  localStorage.setItem(URI_KEY, uri)
  status('接続中…')
  const ok = await connectStored()
  if (ok) loadFeed()
}

function disconnect() {
  bunker.close()
  localStorage.removeItem(URI_KEY)
  userPk = null
  status('未接続(読み取りは既定リレー、投稿には接続が必要)')
  $('btn-disconnect').hidden = true
  loadFeed()
}

async function loadFeed() {
  const list = $('feed')
  list.innerHTML = '<div class="muted">読み込み中…</div>'
  try {
    if (userPk) contacts = await fetchContacts(relays, userPk)
    const notes = await fetchTimeline(relays, userPk, contacts)
    profiles = await fetchProfiles(relays,
      [...new Set(notes.map((n) => n.pubkey))])
    list.innerHTML = ''
    if (!notes.length) {
      list.innerHTML = '<div class="muted">ノートがありません(48時間以内)</div>'
      return
    }
    for (const ev of notes.slice(0, 60)) list.appendChild(noteCard(ev))
  } catch (e) {
    list.innerHTML = `<div class="muted">読み込み失敗: ${e.message}</div>`
  }
}

function noteCard(ev) {
  const p = profiles.get(ev.pubkey) || {}
  const card = document.createElement('article')
  card.className = 'note'
  const name = p.display_name || p.name || `${ev.pubkey.slice(0, 8)}…`
  card.innerHTML =
    `<div class="note-head"><img class="avatar" src="${(p.picture || '').replace(/"/g, '')}" alt="" onerror="this.style.visibility='hidden'">` +
    `<span class="name"></span><span class="time"></span></div><div class="body"></div>`
  card.querySelector('.name').textContent = name
  card.querySelector('.time').textContent = timeLabel(ev.created_at)
  card.querySelector('.body').innerHTML = renderContent(ev.content)
  if (ev.pubkey === userPk) card.classList.add('mine')
  return card
}

async function publish() {
  const text = $('compose').value.trim()
  if (!text) return
  if (!bunker.connected) { status('投稿にはbunker接続が必要です(設定タブ)', false); return }
  $('btn-post').disabled = true
  try {
    const signed = await bunker.signEvent({
      kind: 1, content: text, tags: [], created_at: Math.floor(Date.now() / 1000),
    })
    const res = await relays.publish(signed)
    if (!res.ok) throw new Error('リレーが受け付けませんでした')
    $('compose').value = ''
    const list = $('feed')
    list.prepend(noteCard(signed))
    status('投稿しました', true)
  } catch (e) {
    status(`投稿失敗: ${e.message}`, false)
  } finally {
    $('btn-post').disabled = false
  }
}

function showTab(which) {
  for (const t of ['home', 'settings']) {
    $(`tab-${t}`).classList.toggle('active', t === which)
    $(`view-${t}`).hidden = t !== which
  }
}

$('btn-connect').onclick = connectNew
$('btn-disconnect').onclick = disconnect
$('btn-post').onclick = publish
$('btn-reload').onclick = loadFeed
$('tab-home').onclick = () => showTab('home')
$('tab-settings').onclick = () => showTab('settings')

if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
  navigator.serviceWorker.register('./sw.js').catch(() => {})
}

// Auto-connect on load; the feed reads work with or without the bunker.
;(async () => {
  showTab('home')
  const ok = await connectStored()
  if (!ok) status('未接続 — 設定タブでbunker URIを貼り付けると投稿できます', null)
  loadFeed()
})()
