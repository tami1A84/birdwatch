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
import { DEFAULT_READ_RELAYS, SEARCH_RELAYS, fetchContacts, fetchTimeline, fetchProfiles,
         renderContent, timeLabel, npub } from './feed.js'

const SK_KEY = 'bw_ephem_sk'
const URI_KEY = 'bw_bunker_uri'

const $ = (id) => document.getElementById(id)
const relays = new RelaySet(DEFAULT_READ_RELAYS)
const searchRelays = new RelaySet(SEARCH_RELAYS)
const bunker = new BunkerClient(relays)

let userPk = null
let contacts = []
let profiles = new Map()
let readRelays = [...DEFAULT_READ_RELAYS]

// feed state: interleaving guard, live subscription, dedupe
let feedRun = 0
let lastFeedLoadAt = 0
let seenIds = new Set()
let feedSub = null

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

function emptyState(title, body, icon = 'forum') {
  const el = document.createElement('div')
  el.className = 'empty-state'
  const ic = document.createElement('span')
  ic.className = 'msr empty-state__icon'
  ic.textContent = icon
  const t = document.createElement('p')
  t.className = 'empty-state__title'
  t.textContent = title
  const b = document.createElement('p')
  b.className = 'empty-state__body'
  b.textContent = body
  el.append(ic, t, b)
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
  const run = ++feedRun
  const list = $('feed')
  list.innerHTML = ''
  list.appendChild(emptyState('読み込み中…', 'リレーからタイムラインを取得しています。'))
  lastFeedLoadAt = Date.now()
  try {
    // ページ復帰直後のSafariでは REQ を送っても届かない — 1本でも開くのを待つ
    await relays.ready(6000)
    if (run !== feedRun) return
    let notes
    if (userPk) {
      contacts = await fetchContacts(relays, userPk)
      notes = await fetchTimeline(relays, [...contacts, userPk])
    } else {
      // 未接続(閲覧のみ): フォロー一覧が取れないので全体の最近の投稿を表示
      notes = await fetchTimeline(relays, null)
    }
    if (run !== feedRun) return
    profiles = await fetchProfiles(relays,
      [...new Set(notes.map((n) => n.pubkey))])
    if (run !== feedRun) return
    list.innerHTML = ''
    if (!notes.length) {
      const alive = [...relays.sockets.values()].some((ws) => ws.readyState === 1)
      if (!alive) throw new Error('リレーに接続できません')
      list.appendChild(emptyState('まだ投稿がありません',
        'フォローしたアカウントの投稿や、自分の投稿がここに表示されます。'))
      startLiveFeed()
      return
    }
    seenIds = new Set(notes.map((n) => n.id))
    for (const ev of notes.slice(0, 60)) list.appendChild(noteCard(ev))
    startLiveFeed()
  } catch (e) {
    if (run !== feedRun) return
    list.innerHTML = ''
    const es = emptyState('読み込みに失敗しました', e.message)
    const retry = document.createElement('md-outlined-button')
    retry.textContent = '再試行'
    retry.addEventListener('click', loadFeed)
    es.appendChild(retry)
    list.appendChild(es)
  }
}

// 新着を購読して先頭に差し込む(Rails版のSSE相当)。再接続のたびに REQ が
// 再発行されるのは RelaySet 側。再接続後の再送イベントは id で重複排除。
function startLiveFeed() {
  feedSub?.close()
  const filter = { kinds: [1], since: Math.floor(Date.now() / 1000) }
  if (userPk) filter.authors = [...new Set([...contacts, userPk])].slice(0, 400)
  feedSub = relays.subscribe(filter, (ev) => {
    if (seenIds.has(ev.id)) return
    seenIds.add(ev.id)
    const list = $('feed')
    list.querySelector('.empty-state')?.remove()
    list.prepend(noteCard(ev))
    while (list.children.length > 80) list.lastElementChild.remove()
  })
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
    seenIds.add(signed.id) // ライブ購読のエコーで二重表示にならないように
    $('feed').prepend(noteCard(signed))
    toast('投稿しました')
  } catch (e) {
    toast(`投稿に失敗しました: ${e.message}`)
  } finally {
    btn.disabled = false
  }
}

// ----- search (NIP-50 relay search, narrowed client-side) -------------------

function profileRow(pk, p) {
  const row = document.createElement('div')
  row.className = 'profile-row'
  const av = document.createElement('span')
  av.className = 'avatar avatar--sm'
  const img = document.createElement('img')
  img.alt = ''
  img.loading = 'lazy'
  if (p.picture) {
    img.src = p.picture
    img.onerror = () => { img.style.visibility = 'hidden' }
  } else {
    img.style.visibility = 'hidden'
  }
  av.appendChild(img)
  const body = document.createElement('span')
  body.className = 'profile-row__body'
  const name = document.createElement('span')
  name.className = 'profile-row__name'
  name.textContent = p.display_name || p.name || `${pk.slice(0, 8)}…`
  const sub = document.createElement('span')
  sub.className = 'profile-row__sub'
  sub.textContent = p.nip05 || `${npub(pk).slice(0, 20)}…`
  body.append(name, sub)
  row.append(av, body)
  return row
}

function searchSection(title, nodes) {
  const sec = document.createElement('div')
  const h = document.createElement('h2')
  h.className = 'section-title'
  h.textContent = title
  sec.appendChild(h)
  for (const n of nodes) sec.appendChild(n)
  return sec
}

async function runSearch(q) {
  const box = $('search-results')
  if (!q) return
  box.innerHTML = ''
  box.appendChild(emptyState('検索中…', 'リレーに問い合わせています。', 'search'))
  searchRelays.open()
  await searchRelays.ready(4000)
  const [noteHits, profileHits] = await Promise.all([
    searchRelays.query({ kinds: [1], search: q, limit: 50 }, 10000),
    searchRelays.query({ kinds: [0], search: q, limit: 20 }, 10000),
  ])
  // NIP-50 非対応リレーは search を無視して雑多な最近のイベントを返すことが
  // あるので、内容側でも再度絞り込む(二重でも安全側に倒す)。
  const ql = q.toLowerCase()
  const matches = (s) => String(s || '').toLowerCase().includes(ql)
  const notes = noteHits
    .filter((ev) => matches(ev.content))
    .sort((a, b) => b.created_at - a.created_at)
  const profs = []
  for (const ev of profileHits.sort((a, b) => b.created_at - a.created_at)) {
    let meta = {}
    try { meta = JSON.parse(ev.content) } catch { /* keep empty */ }
    profiles.set(ev.pubkey, meta) // 検索で得たプロフィールはフィード側でも使う
    if (matches(meta.name) || matches(meta.display_name) ||
        matches(meta.nip05) || matches(meta.about)) {
      if (!profs.some((x) => x.pk === ev.pubkey)) profs.push({ pk: ev.pubkey, meta })
    }
  }
  box.innerHTML = ''
  if (!profs.length && !notes.length) {
    box.appendChild(emptyState(`「${q}」に一致するものがありません`,
      '別のキーワードで試してください。', 'search_off'))
    return
  }
  if (profs.length) {
    box.appendChild(searchSection('プロフィール',
      profs.slice(0, 10).map((x) => profileRow(x.pk, x.meta))))
  }
  if (notes.length) {
    const feed = document.createElement('div')
    feed.className = 'feed feed--search'
    for (const ev of notes.slice(0, 30)) feed.appendChild(noteCard(ev))
    box.appendChild(searchSection('投稿', [feed]))
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

const on = (id, ev, fn) => $(id)?.addEventListener(ev, fn)

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

on('btn-search', 'click', () => {
  $('search-dialog').show()
  requestAnimationFrame(() => $('search-input').focus())
})
on('search-close', 'click', () => $('search-dialog').close())
on('search-form', 'submit', (e) => {
  e.preventDefault()
  runSearch($('search-input').value.trim())
})

if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
  navigator.serviceWorker.register('./sw.js').catch(() => {})
}

// Safari はバックグラウンド中にソケットを静かに殺す。復帰したら張り直し、
// 前回のフィード取得から2分以上経過していればタイムラインも取り直す。
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return
  relays.revive()
  if (Date.now() - lastFeedLoadAt > 2 * 60 * 1000) loadFeed()
})

// Home first; the feed reads work with or without the bunker.
showView(0)
;(async () => {
  // 全体フィードを先に出し(未接続でも読める)、接続が決まったらフォロイーの
  // タイムラインを取り直す。旧実装は接続待ちとフィード取得が競合し、userPk が
  // 決まる前に authors:[null] の REQ を飛ばすため、起動直後は常に空表示だった。
  // さらに default リレーの open() が一度も呼ばれていなかった(bunker接続時の
  // addUrls でのみソケットが張られる)ので、未接続だと REQ がどこにも届かなかった。
  relays.open()
  loadFeed()
  const ok = await connectStored()
  if (!ok) renderBunkerState('未接続(閲覧のみ)')
  else loadFeed()
})()
