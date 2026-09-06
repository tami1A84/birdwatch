// birdwatch static shell — app files cache-first, navigations network-first.
// Navigations (the HTML) go to the network first so an update ships on the
// next app open; the cached copy is the offline fallback. Everything else is
// cache-first with a version bump to force a refresh.
const CACHE = 'bw-shell-v5'
const ASSETS = ['./', './app.js', './style.css', './manifest.webmanifest',
                './icon-64.png', './icon-192.png', './icon-512.png',
                './favicon.ico',
                './roboto-serif-latin.woff2', './material-symbols-rounded.woff2']
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
  e.respondWith(
    caches.match(e.request).then((hit) => hit || fetch(e.request).then((res) => {
      const copy = res.clone()
      caches.open(CACHE).then((c) => c.put(e.request, copy))
      return res
    })))
})
