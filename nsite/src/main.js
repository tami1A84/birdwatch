// birdwatch static app — browser-side wiring.
//
// Visual + interaction parity with the Rails web app (Material 3
// Expressive): app-bar header (search + settings toggle), compose FAB +
// dialog, serif timeline rows. Reads: home timeline straight from relays
// (feed.js).
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
import jsQR from "jsqr";
import { RelaySet } from './relay-set.js'
import { generateSecretKey } from 'nostr-tools'
import { BunkerClient, parseBunkerUri } from './nip46.js'
import { DEFAULT_READ_RELAYS, SEARCH_RELAYS, fetchContacts, fetchTimeline, fetchProfiles,
         renderContent, timeLabel, npub } from './feed.js'

// app.js モジュールの評価が始まった印。index.html の12sフェイルセーフは、
// この印が無い場合(import解決失敗/JS死)だけスプラッシュを外す。印があれば
// いくら遅くても revealApp() が面倒を見るので、健全なアプリが空のシェルを
// 見せることはない。
document.documentElement.dataset.bwBooted = '1'

const SK_KEY = 'bw_ephem_sk'
const URI_KEY = 'bw_bunker_uri'
const PK_KEY = 'bw_user_pk'

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
// 起動制御: whenConnected は起動時のbunker接続の完了(loadFeed が短く待てる
// ように)。lastFeedMode/lastFeedPk は最後の loadFeed が何を表示したか —
// 接続後に取り直しが本当に必要かの判定に使う。
let whenConnected = null
let lastFeedMode = null
let lastFeedPk = null

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
    // フォロー一覧(kind 3)は公開イベントなので、次回起動はこの鍵で bunker
    // 待ちなしにフォロイーのタイムラインを直接取りに行ける。
    localStorage.setItem(PK_KEY, userPk)
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
  localStorage.removeItem(PK_KEY)
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

// 未接続時に出す案内。全体フィードへのフォールバックは廃止(N, 2026-09-07):
// タイムラインはbunker接続前提なので、接続方法の案内とボタンだけを置く。
// pending中の接続が後から決まった場合は起動フックがフォロイーに差し替える。
function showNotConnected(list) {
  lastFeedMode = 'not-connected'
  lastFeedPk = null
  list.innerHTML = ''
  const es = emptyState('接続していません',
    'タイムラインはフォロー中のアカウントの投稿です。設定でbunkerに接続すると表示されます。')
  if (localStorage.getItem(URI_KEY)) {
    const retry = document.createElement('md-outlined-button')
    retry.textContent = '再接続'
    retry.addEventListener('click', () => {
      whenConnected = connectStored(() => loadFeed())
    })
    es.appendChild(retry)
  }
  const open = document.createElement('md-filled-button')
  open.textContent = '設定を開く'
  open.addEventListener('click', () => showView(1))
  es.appendChild(open)
  list.appendChild(es)
  return lastFeedMode
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
  // 読み込みプレースホルダーは廃止(N, 2026-09-07「毎回出るので消して」)。
  // 遅延表示でも遅い回線では毎回出てしまい点滅にしか見えないため、結果が出る
  // までリストは空のまま。未接続の案内とエラー時の再試行は残す。
  lastFeedLoadAt = Date.now()
  try {
    // 未接続でURIも無いなら読みに行くものが無い — リレー待ちもREQも不要で、
    // 即案内を出す。
    if (!userPk && !localStorage.getItem(URI_KEY)) {
      return showNotConnected(list)
    }
    // ページ復帰直後のSafariでは REQ を送っても届かない — 1本でも開くのを待つ
    await relays.ready(6000)
    if (run !== feedRun) return
    // 起動直後でbunker接続がまだ決まっていないなら短く待つ(フォロイーの
    // タイムラインを最初から出すため)。8秒で決まらなくても全体表示には落とさ
    // ない — 未接続の案内を出し、接続が後から決まれば起動フックが差し替える。
    if (!userPk && whenConnected) {
      await Promise.race([
        whenConnected,
        new Promise((r) => setTimeout(r, 8000)),
      ])
      if (run !== feedRun) return
    }
    if (!userPk) {
      return showNotConnected(list)
    }
    lastFeedMode = 'following'
    lastFeedPk = userPk
    contacts = await fetchContacts(relays, userPk)
    const notes = await fetchTimeline(relays, [...contacts, userPk])
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
      return lastFeedMode
    }
    seenIds = new Set(notes.map((n) => n.id))
    for (const ev of notes.slice(0, 60)) list.appendChild(noteCard(ev))
    startLiveFeed()
    return lastFeedMode
  } catch (e) {
    if (run !== feedRun) return lastFeedMode
    list.innerHTML = ''
    const es = emptyState('読み込みに失敗しました', e.message)
    const retry = document.createElement('md-outlined-button')
    retry.textContent = '再試行'
    retry.addEventListener('click', loadFeed)
    es.appendChild(retry)
    list.appendChild(es)
    return lastFeedMode
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

// 投稿ダイアログ。下書きはlocalStorageに常時退避する: アプリがバックグラ
// ウンドに回ると closeOverlays() が自動で閉じるため(iOSスナップショット対策)、
// 書きかけが消えないように。投稿成功でクリア、キャンセルでは保持(従来動作:
// 閉じてもテキストは残る、と同じ)。
const DRAFT_KEY = 'bw_compose_draft'

function openCompose() {
  const dialog = $('compose-dialog')
  if (!dialog) return
  $('compose-text').value = localStorage.getItem(DRAFT_KEY) || ''
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
    localStorage.removeItem(DRAFT_KEY)
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

// ----- PWA install guidance ------------------------------------------------
// iOS Safari はネイティブのインストール促導を出さない仕様(「ホーム画面に
// 追加」は共有メニューから行う)。そこでiOSには手順を案内するバナーを出し、
// Android/Chrome では beforeinstallprompt を拾ってネイティブダイアログを出す。
// スタンドアロンで起動されている時(=もうインストール済み)は何も出さない。

function setupInstallHint() {
  const banner = $('install-banner')
  if (!banner) return
  const standalone = matchMedia('(display-mode: standalone)').matches ||
    navigator.standalone === true
  if (standalone || localStorage.getItem('bw_install_dismissed') === '1') return
  const ios = /iPhone|iPad|iPod/i.test(navigator.userAgent)
  const textEl = banner.querySelector('.install-banner__text')
  const btn = $('install-button')
  let deferred = null
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault()
    deferred = e
    if (ios || banner.hidden === false) return
    textEl.textContent = 'ホーム画面に追加してアプリとして使えます。'
    btn.style.display = ''
    banner.hidden = false
  })
  if (ios) {
    textEl.textContent = 'ホーム画面に追加: Safari下部の共有ボタン →「ホーム画面に追加」'
    banner.hidden = false
  }
  btn.addEventListener('click', async () => {
    if (!deferred) return
    deferred.prompt()
    try { await deferred.userChoice } catch { /* 閉じられただけ */ }
    deferred = null
    banner.hidden = true
  })
  $('install-close').addEventListener('click', () => {
    banner.hidden = true
    localStorage.setItem('bw_install_dismissed', '1')
  })
}

// ----- navigation ----------------------------------------------------------
// No bottom nav (N, 2026-09-06 round 3): the app-bar settings button opens
// settings and doubles as "back" while inside it; home is the only tab.

const VIEWS = [
  { id: 'home', title: 'birdwatch' },
  { id: 'settings', title: '設定' },
]

let currentView = 0

function showView(i) {
  currentView = i
  for (const [n, v] of VIEWS.entries()) $(`view-${v.id}`).hidden = n !== i
  $('appbar-title').textContent = VIEWS[i].title
  $('compose-fab').style.display = i === 0 ? '' : 'none' // md-fab ignores [hidden]
  const settingsIcon = $('btn-settings')?.querySelector('.msr')
  if (settingsIcon) {
    settingsIcon.textContent = i === 0 ? 'settings' : 'arrow_back'
    $('btn-settings').setAttribute('aria-label', i === 0 ? '設定' : '戻る')
  }
}

// ----- boot splash reveal (N, 2026-09-07 round 3) ---------------------------
// index.html は静的なスプラッシュ(アプリアイコンの脈動)を持ち、app.js が
// 最初の実状態を描くまで body.booting で他の全要素を隠している。reveal は
// タイムライン/未接続案内/エラーのいずれかが実際に置かれた直後だけ。
// 「タイムライン表示の前に何も表示させない」のため、シェルだけの状態は
// 一瞬も見せない。
let revealed = false

function revealApp() {
  if (revealed) return
  revealed = true
  document.body.classList.remove('booting')
  const splash = $('splash')
  if (splash) {
    splash.style.opacity = '0'
    setTimeout(() => splash.remove(), 300)
  }
}

// ----- snapshot hygiene (N, 2026-09-07 round 3) -----------------------------
// iOS はホーム画面アプリの「最後の見た目」を次回起動時に一瞬出す(スナップ
// ショット)。QRスキャン(カメラ)や投稿ダイアログを開いたままバックグラウンド
// に回ると、次回起動の最初の一枚がそのダイアログになる — これがNのスクショ
// の正体。アプリが前景を離れる時はオーバーレイを全部閉じてカメラも止めるの
// で、スナップショットは常に素のアプリ画面になる。composeの下書きは
// localStorageに退避するので、自動クローズで書きかけが消えることはない。
function closeOverlays() {
  for (const id of ['compose-dialog', 'qr-dialog', 'search-dialog']) {
    const d = $(id)
    // quick=true: M3のクローズアニメーション(~250-400ms)をスキップし、この
    // タスク内でネイティブのdialogを閉じきる。アニメーション中のフレームを
    // iOSがスナップショットすると結局ダイアログが写るため(review指摘)。
    if (d?.open) { d.quick = true; d.close() }
  }
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') closeOverlays()
})
window.addEventListener('pagehide', closeOverlays)
window.addEventListener('freeze', closeOverlays) // Page Lifecycle (対応時のみ発火)

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

on('btn-settings', 'click', () => showView(currentView === 0 ? 1 : 0))

$('bunker-form').addEventListener('submit', (e) => {
  e.preventDefault()
  connectNew()
})
$('btn-disconnect').addEventListener('click', disconnect)

$('compose-fab').addEventListener('click', openCompose)
$('compose-text').addEventListener('input', (e) => {
  localStorage.setItem(DRAFT_KEY, e.target.value)
})
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

setupInstallHint()

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

// Home first. Feed reads require the bunker — no global-feed fallback since
// 2026-09-07 (N): an unconnected app shows the connect prompt only.
showView(0)
;(async () => {
  // フォロー一覧(kind 3)は公開イベントなので、前回接続時にキャッシュした
  // 公開鍵があればbunkerの接続を待たずにフォロイーのタイムラインを直接取りに
  // 行く。未接続時に全体フィードへフォールバックする挙動は廃止(2026-09-07
  // N指摘): 接続が決まるまでは接続を促す案内を出すだけ。
  relays.open()
  const cachedPk = localStorage.getItem(PK_KEY)
  if (cachedPk) {
    userPk = cachedPk
    try {
      const uri = localStorage.getItem(URI_KEY)
      if (uri) relays.addUrls(parseBunkerUri(uri).relays)
    } catch { /* URIが壊れていてもデフォルトリレーで読める */ }
  }
  whenConnected = connectStored()
  const firstMode = await loadFeed()
  revealApp()
  const ok = await whenConnected
  // 8秒以内に接続が決まっていれば loadFeed は既にフォロイーを出しているので
  // 何もしない。未接続案内のまま残った場合(接続の遅延/失敗)と、接続で公開鍵が
  // 入れ替わった場合だけ、ここでフォロイーに差し替える。
  if (ok && (firstMode !== 'following' || lastFeedPk !== userPk)) loadFeed()
})()
