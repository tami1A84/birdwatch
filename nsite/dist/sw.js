// birdwatch static shell — cache-first for app files only.
const CACHE = 'bw-shell-v2'
const ASSETS = ['./', './app.js', './style.css', './manifest.webmanifest',
                './icon-64.png', './icon-192.png', './icon-512.png',
                './favicon.ico',
                './roboto-serif-latin.woff2', './material-symbols-rounded.woff2']
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)))
})
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) =>
    Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))))
})
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET' || !e.request.url.startsWith(self.location.origin)) return
  e.respondWith(
    caches.match(e.request).then((hit) => hit || fetch(e.request).then((res) => {
      const copy = res.clone()
      caches.open(CACHE).then((c) => c.put(e.request, copy))
      return res
    })))
})
