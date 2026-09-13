// Kosten Fichaje — service worker mínimo
// Por ahora solo habilita que la app sea "instalable" (PWA) y deja
// cacheado el cascarón de la app para que abra más rápido.
// El envío de notificaciones push se agrega en un paso posterior.

const CACHE_NAME = "kosten-shell-v1";
const SHELL_FILES = [
  "./",
  "./index.html",
  "./manifest.json",
  "./kosten-wordmark.png",
  "./icon-192.png",
  "./icon-512.png",
];

self.addEventListener("install", (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES).catch(() => {}))
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Estrategia simple: red primero, y si falla (sin conexión) usa el cache.
// Los datos (Supabase) siempre van directo a la red, nunca al cache.
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return; // no tocar llamadas a Supabase/CDNs

  event.respondWith(
    fetch(event.request)
      .then((res) => {
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(event.request))
  );
});

// Lugar preparado para notificaciones push (fase siguiente)
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) {}
  const title = data.title || "Kosten";
  const body = data.body || "Tenés una notificación pendiente.";
  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      icon: "icon-192.png",
      badge: "icon-192.png",
    })
  );
});
