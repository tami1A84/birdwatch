// birdwatch static shell — navigations network-first, app code stale-while-revalidate.
// Navigations (the HTML) go to the network first so an update ships on the next
// app open. app.js / style.css answer from cache instantly and revalidate against
// the network in the background, so a publish lands on the next launch without
// editing this file (nsite.lol caches each path for up to 1h, so expect at most
// that much lag). Icons/fonts are effectively immutable: cache-first.
// Bump CACHE only when a bad build must be evicted from clients at once.
const CACHE = 'bw-shell-v16'
const APP_FILES = ['/app.js', '/style.css']
const ASSETS = ['./', './app.js', './style.css', './manifest.webmanifest',
                './icon-64.png', './icon-192.png', './icon-512.png',
                './favicon.ico',
                './line-seed-jp-regular.woff2', './line-seed-jp-bold.woff2',
                './line-seed-jp-OFL.txt', './material-symbols-rounded.woff2']
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()))
})
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) =>
    Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()))
})
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET' || !e.request.url.startsWith(self.location.origin)) return
  if (e.request.mode === 'navigate') {
    e.respondWith(
      fetch(e.request).then((res) => {
        const copy = res.clone()
        caches.open(CACHE).then((c) => c.put(e.request, copy))
        return res
      }).catch(() => caches.match('./')))
    return
  }
  if (APP_FILES.includes(new URL(e.request.url).pathname)) {
    e.respondWith(
      caches.match(e.request).then((hit) => {
        const refresh = fetch(e.request).then((res) => {
          if (res && res.ok) {
            const copy = res.clone()
            caches.open(CACHE).then((c) => c.put(e.request, copy))
          }
          return res
        }).catch(() => hit)
        return hit || refresh
      }))
    return
  }
  e.respondWith(
    caches.match(e.request).then((hit) => hit || fetch(e.request).then((res) => {
      const copy = res.clone()
      caches.open(CACHE).then((c) => c.put(e.request, copy))
      return res
    })))
})
