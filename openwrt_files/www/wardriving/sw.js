const CACHE_NAME = 'owrt-store-v4';
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

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_ASSETS)));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
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
