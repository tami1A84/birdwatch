// birdwatch static app — browser-side wiring.
//
// Visual + interaction parity with the Rails web app (Material 3
// Expressive): app-bar header, bottom navigation, compose FAB + dialog,
// serif timeline rows. Reads: home timeline straight from relays (feed.js).
// Writes: NIP-46 via the user's daemon bunker (nip46.js) — the browser
// never holds the identity key, only an ephemeral client key in
// localStorage. Settings additionally pairs the bunker by scanning the
// daemon's connect QR with the device camera.
import "@material/web/button/filled-button.js";
import "@material/web/button/outlined-button.js";
import "@material/web/button/text-button.js";
import "@material/web/iconbutton/icon-button.js";
import "@material/web/fab/fab.js";
import "@material/web/dialog/dialog.js";
import "@material/web/labs/navigationbar/navigation-bar.js";
import "@material/web/labs/navigationtab/navigation-tab.js";
import jsQR from "jsqr";
import { RelaySet } from './relay-set.js'
import { generateSecretKey } from 'nostr-tools'
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

// ----- toast (same pattern as the Rails app) -------------------------------

function toast(message) {
  const bar = $('app-toast')
  if (!bar) return
  bar.textContent = message
  bar.classList.add('toast--show')
  clearTimeout(toast._t)
  toast._t = setTimeout(() => bar.classList.remove('toast--show'), 3500)
}

// ----- ephemeral client key ------------------------------------------------

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

// ----- bunker connection ---------------------------------------------------

function renderBunkerState(text, connected = null) {
  $('bunker-state').textContent = text
  // md-* hosts ship their own display style, which beats the UA [hidden] rule.
  $('btn-disconnect').style.display = connected === true ? '' : 'none'
}

async function connectStored(onDone = () => {}) {
  const uri = localStorage.getItem(URI_KEY)
  if (!uri) { renderBunkerState('未接続(閲覧のみ)'); return false }
  renderBunkerState('接続中…')
  try {
    const parsed = parseBunkerUri(uri)
    readRelays = [...new Set([...parsed.relays, ...DEFAULT_READ_RELAYS])]
    userPk = await bunker.connect(uri, ephemeralKey(),
      (text) => renderBunkerState(text))
    renderBunkerState('接続済み', true)
    $('acct-pk').textContent = `${npub(userPk).slice(0, 16)}…`
    $('bunker-uri').value = uri
    onDone()
    return true
  } catch (e) {
    renderBunkerState('未接続(閲覧のみ)')
    toast(`bunker接続に失敗: ${e.message}`)
    return false
  }
}

async function connectNew() {
  const uri = $('bunker-uri').value.trim()
  if (!uri) { toast('bunker URIを貼り付けてください'); return }
  bunker.close()
  localStorage.setItem(URI_KEY, uri)
  const ok = await connectStored()
  if (ok) { toast('bunkerに接続しました'); loadFeed() }
}

function disconnect() {
  bunker.close()
  localStorage.removeItem(URI_KEY)
  $('bunker-uri').value = ''
  userPk = null
  $('acct-pk').textContent = '—'
  renderBunkerState('未接続(閲覧のみ)')
  toast('bunkerから切断しました')
  loadFeed()
}

// ----- home timeline -------------------------------------------------------

function emptyState(title, body) {
  const el = document.createElement('div')
  el.className = 'empty-state'
  const icon = document.createElement('span')
  icon.className = 'msr empty-state__icon'
  icon.textContent = 'forum'
  const t = document.createElement('p')
  t.className = 'empty-state__title'
  t.textContent = title
  const b = document.createElement('p')
  b.className = 'empty-state__body'
  b.textContent = body
  el.append(icon, t, b)
  return el
}

function noteCard(ev) {
  const p = profiles.get(ev.pubkey) || {}
  const card = document.createElement('article')
  card.className = 'tl-item'

  const avatar = document.createElement('img')
  avatar.className = 'avatar--lg'
  avatar.alt = ''
  avatar.loading = 'lazy'
  if (p.picture) {
    avatar.src = p.picture
    avatar.onerror = () => { avatar.style.visibility = 'hidden' }
  } else {
    avatar.style.visibility = 'hidden'
  }
  const av = document.createElement('span')
  av.className = 'tl-item__avatar'
  av.appendChild(avatar)

  const main = document.createElement('span')
  main.className = 'tl-item__main'
  const head = document.createElement('span')
  head.className = 'tl-item__head'
  const name = document.createElement('span')
  name.className = 'tl-item__name'
  name.textContent = p.display_name || p.name || `${ev.pubkey.slice(0, 8)}…`
  const time = document.createElement('span')
  time.className = 'tl-item__time'
  time.textContent = timeLabel(ev.created_at)
  head.append(name, time)
  const body = document.createElement('span')
  body.className = 'tl-item__body'
  body.innerHTML = renderContent(ev.content)
  main.append(head, body)

  card.append(av, main)
  return card
}

async function loadFeed() {
  const list = $('feed')
  list.innerHTML = ''
  list.appendChild(emptyState('読み込み中…', 'リレーからタイムラインを取得しています。'))
  try {
    if (userPk) contacts = await fetchContacts(relays, userPk)
    const notes = await fetchTimeline(relays, userPk, contacts)
    profiles = await fetchProfiles(relays,
      [...new Set(notes.map((n) => n.pubkey))])
    list.innerHTML = ''
    if (!notes.length) {
      list.appendChild(emptyState('まだ投稿がありません',
        'フォローしたアカウントの投稿や、自分の投稿がここに表示されます。'))
      return
    }
    for (const ev of notes.slice(0, 60)) list.appendChild(noteCard(ev))
  } catch (e) {
    list.innerHTML = ''
    list.appendChild(emptyState('読み込みに失敗しました', e.message))
  }
}

// ----- compose dialog ------------------------------------------------------

function openCompose() {
  const dialog = $('compose-dialog')
  if (!dialog) return
  dialog.show()
  requestAnimationFrame(() => $('compose-text').focus())
}

async function submitCompose() {
  const text = $('compose-text').value.trim()
  if (!text) return
  if (!bunker.connected) { toast('投稿にはbunker接続が必要です(設定タブ)'); return }
  const btn = $('compose-submit')
  btn.disabled = true
  try {
    const signed = await bunker.signEvent({
      kind: 1, content: text, tags: [], created_at: Math.floor(Date.now() / 1000),
    })
    const res = await relays.publish(signed)
    if (!res.ok) throw new Error('リレーが受け付けませんでした')
    $('compose-text').value = ''
    $('compose-dialog').close()
    $('feed').prepend(noteCard(signed))
    toast('投稿しました')
  } catch (e) {
    toast(`投稿に失敗しました: ${e.message}`)
  } finally {
    btn.disabled = false
  }
}

// ----- navigation ----------------------------------------------------------

const VIEWS = [
  { id: 'home', title: 'birdwatch' },
  { id: 'settings', title: '設定' },
]

function showView(i) {
  for (const [n, v] of VIEWS.entries()) $(`view-${v.id}`).hidden = n !== i
  $('appbar-title').textContent = VIEWS[i].title
  $('compose-fab').style.display = i === 0 ? '' : 'none' // md-fab ignores [hidden]
}

// ----- QR camera scan (pair the bunker by reading the daemon's QR) ----------

let qrStream = null
let qrTimer = null

function stopQr() {
  if (qrTimer) { clearInterval(qrTimer); qrTimer = null }
  if (qrStream) {
    qrStream.getTracks().forEach((t) => t.stop())
    qrStream = null
  }
  $('qr-video').srcObject = null
}

async function startQr() {
  const video = $('qr-video')
  $('qr-dialog').show()
  $('qr-status').textContent = 'カメラを起動しています…'
  try {
    qrStream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment' }, audio: false,
    })
  } catch (e) {
    $('qr-status').textContent = `カメラにアクセスできませんでした: ${e.message}`
    return
  }
  video.srcObject = qrStream
  try { await video.play() } catch { /* muted autoplay is allowed anyway */ }
  const detector = 'BarcodeDetector' in window
    ? new window.BarcodeDetector({ formats: ['qr_code'] })
    : null
  const canvas = document.createElement('canvas')
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  $('qr-status').textContent = 'PCのQRを読み取っています…'
  qrTimer = setInterval(async () => {
    if (qrTimer === null || video.readyState < 2) return
    const w = 480
    const h = Math.round((video.videoHeight / video.videoWidth) * w) || 360
    canvas.width = w
    canvas.height = h
    ctx.drawImage(video, 0, 0, w, h)
    let text = null
    try {
      if (detector) {
        const hits = await detector.detect(canvas)
        if (hits.length) text = hits[0].rawValue
      } else {
        const img = ctx.getImageData(0, 0, w, h)
        const hit = jsQR(img.data, w, h)
        if (hit) text = hit.data
      }
    } catch { /* transient frame issue — try the next one */ }
    if (text && text.startsWith('bunker://')) {
      stopQr()
      $('qr-dialog').close()
      $('bunker-uri').value = text
      toast('QRからbunker URIを読み取りました')
      connectNew()
    } else if (text) {
      $('qr-status').textContent = 'これはbunker URIのQRではありません'
    }
  }, 250)
}

// ----- wiring ---------------------------------------------------------------

$('navbar').addEventListener('navigation-bar-activated', (e) => {
  const tab = e.detail?.tab
  if (!tab) return
  showView([...$('navbar').children].indexOf(tab))
})

$('bunker-form').addEventListener('submit', (e) => {
  e.preventDefault()
  connectNew()
})
$('btn-disconnect').addEventListener('click', disconnect)

$('compose-fab').addEventListener('click', openCompose)
$('compose-cancel').addEventListener('click', () => $('compose-dialog').close())
$('compose-submit').addEventListener('click', submitCompose)

$('btn-qr').addEventListener('click', startQr)
$('qr-cancel').addEventListener('click', () => {
  stopQr()
  $('qr-dialog').close()
})
$('qr-dialog').addEventListener('close', stopQr)

if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
  navigator.serviceWorker.register('./sw.js').catch(() => {})
}

// Home first; the feed reads work with or without the bunker.
showView(0)
;(async () => {
  loadFeed()
  const ok = await connectStored()
  if (!ok) renderBunkerState('未接続(閲覧のみ)')
})()
