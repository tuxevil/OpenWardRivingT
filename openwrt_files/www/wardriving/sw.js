const CACHE_NAME = 'owrt-store-v10';
const APP_ASSETS = [
  './',
  './index.html',
  './app.css',
  './app.js',
  './leaflet.css',
  './leaflet.js',
  './leaflet-heat.js',
  './manifest.json'
];

// Don't auto-skipWaiting on install. The previous version (v9) used
// self.skipWaiting() in the install handler, which combined with
// clients.claim() in activate caused any open dashboard tab to
// suddenly be hijacked by the new SW on deploy — losing the live
// GPS position, the map state, and any in-flight UI state.
// Instead we let the new SW wait for all tabs to close naturally
// (or until the user explicitly reloads). Active users stay on
// the old SW; new navigations pick up the new one.
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_ASSETS)));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      // clients.claim() only takes over tabs that load AFTER
      // activation, not the ones that triggered the activation.
      .then(() => self.clients.claim())
  );
});

// Allow the dashboard to force-activate the waiting SW via a
// postMessage: navigator.serviceWorker.controller.postMessage({type: 'SKIP_WAITING'})
// Useful for an "update available" toast the dashboard can show.
self.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

function isAppShellRequest(request) {
  const url = new URL(request.url);
  return request.mode === 'navigate' ||
    url.pathname === '/wardriving/' ||
    APP_ASSETS.some((asset) => url.pathname.endsWith('/wardriving/' + asset.replace('./', '')));
}

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.pathname.indexOf('/cgi-bin/wardriving_api') !== -1) {
    e.respondWith(fetch(e.request));
    return;
  }

  if (isAppShellRequest(e.request)) {
    e.respondWith(
      fetch(e.request)
        .then((response) => {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(e.request, copy));
          return response;
        })
        .catch(() => caches.match(e.request).then((response) => response || caches.match('./index.html')))
    );
    return;
  }

  e.respondWith(caches.match(e.request).then((response) => response || fetch(e.request)));
});
