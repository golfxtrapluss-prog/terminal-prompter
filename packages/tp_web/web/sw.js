// Terminal Prompter service worker (docs/16 "Installerbar app").
// Caches the client files so the app opens instantly on slow links and
// shows its own offline state instead of a blank page. API traffic is
// never cached.
const VERSION = '__TP_VERSION__';
const CACHE = 'tp-' + VERSION;
const ASSETS = [
  './', 'index.html', 'styles.css', 'main.dart.js', 'manifest.webmanifest',
  'vendor/xterm/xterm.js', 'vendor/xterm/xterm.css', 'vendor/xterm/addon-fit.js',
  'vendor/xterm/addon-web-links.js', 'vendor/xterm/addon-search.js',
  'vendor/xterm/addon-unicode11.js', 'icons/icon-192.png', 'icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== 'GET' || url.pathname.includes('/api/') || url.pathname.endsWith('/healthz')) {
    return; // network only
  }
  if (req.mode === 'navigate') {
    // Network first so a new agent version is picked up; cache as fallback.
    event.respondWith(fetch(req).catch(() => caches.match('index.html')));
    return;
  }
  event.respondWith(
    caches.match(req).then((hit) => hit || fetch(req).then((res) => {
      if (res.ok && url.origin === self.location.origin) {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
      }
      return res;
    })),
  );
});
