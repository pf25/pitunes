// PiTunes service worker: makes the web app work without a connection.
//
// A service worker is a small script the browser keeps running beside the
// page. Every request the page makes passes through `fetch` below, so we can
// answer from storage on the device when the Pi can't be reached. Browsers
// only allow this on a secure (https) address.
//
// Four stores:
//   shell  the app itself (page, script, styles, icons)
//   audio  songs you downloaded, saved under /stream/<id>
//   art    artwork for downloaded songs
//   data   the last copy of each list the app loaded (likes, playlists...)
"use strict";

const SHELL = "pitunes-shell-v1", AUDIO = "pitunes-audio", ART = "pitunes-art", DATA = "pitunes-data";
const SHELL_FILES = ["/", "/web/app.js", "/web/style.css", "/web/icon-180.png", "/web/icon-512.png", "/web/manifest.webmanifest"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(SHELL).then((cache) => cache.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== location.origin) return;   // let the browser handle it

  if (url.pathname.startsWith("/stream/")) return event.respondWith(song(request, url));
  if (url.pathname === "/img") return event.respondWith(cacheFirst(request, ART));
  if (url.pathname === "/" || url.pathname.startsWith("/web/")) return event.respondWith(networkFirst(request, SHELL, url.pathname));
  if (["/health", "/backup", "/cache"].includes(url.pathname) || url.pathname.startsWith("/resolve/")) return;
  event.respondWith(networkFirst(request, DATA, request.url));               // lists and pages of data
});

/** Try the Pi first (so you always see the latest); fall back to the saved copy. */
async function networkFirst(request, cacheName, key) {
  const cache = await caches.open(cacheName);
  try {
    const response = await fetch(request);
    if (response.ok) cache.put(key, response.clone());
    return response;
  } catch (error) {
    const saved = await cache.match(key);
    if (saved) return saved;
    throw error;
  }
}

/** Use the saved copy if there is one; otherwise ask the Pi (without saving). */
async function cacheFirst(request, cacheName) {
  const saved = await (await caches.open(cacheName)).match(request.url);
  return saved || fetch(request);
}

/** A song: from the device if it was downloaded, otherwise from the Pi.
 *  Audio players ask for a file in pieces ("Range: bytes=0-999"), so a
 *  downloaded song has to be cut up and answered piece by piece. */
async function song(request, url) {
  const saved = await (await caches.open(AUDIO)).match(url.pathname);
  if (!saved) return fetch(request);
  const blob = await saved.blob();
  const type = saved.headers.get("Content-Type") || "audio/mp4";
  const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.get("Range") || "");
  if (!range) {
    return new Response(blob, { headers: { "Content-Type": type, "Content-Length": String(blob.size), "Accept-Ranges": "bytes" } });
  }
  let start = range[1] ? Number(range[1]) : blob.size - Number(range[2]);     // "bytes=-500" means the last 500
  let end = range[1] && range[2] ? Number(range[2]) : blob.size - 1;
  start = Math.max(0, start);
  end = Math.min(end, blob.size - 1);
  if (start > end) return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${blob.size}` } });
  return new Response(blob.slice(start, end + 1, type), { status: 206, headers: {
    "Content-Type": type, "Content-Length": String(end - start + 1),
    "Content-Range": `bytes ${start}-${end}/${blob.size}`, "Accept-Ranges": "bytes" } });
}
