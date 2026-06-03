self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open('owrt-store').then((cache) => cache.addAll([
      './',
      './index.html',
      './leaflet.css',
      './leaflet.js',
      './leaflet-heat.js',
      './manifest.json'
    ]))
  );
});

self.addEventListener('fetch', (e) => {
  e.respondWith(
    caches.match(e.request).then((response) => response || fetch(e.request))
  );
});
