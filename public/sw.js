/* Meetspike service worker.
 *
 * Its one job is to make every deploy show up without reinstalling, while
 * still opening when the network is bad.
 *
 * - VERSION is stamped at deploy time by scripts/stamp-version.mjs (commit
 *   sha + time). A new value makes this file byte-different, which is how the
 *   browser knows there is a new worker. "dev" means unstamped (local dev).
 * - The new worker installs, skips waiting and claims open pages at once.
 *   The page (public/pwa.js) then reloads at a quiet moment.
 * - Pages and app code are network-first: always the newest deploy when
 *   online, the last good copy only when offline.
 * - /api, /auth, /hooks and /setup are never touched: they go straight to the
 *   network exactly as without a service worker (Cloudflare Access, OAuth).
 */
const VERSION = "dev";
const PREFIX = "meetspike-";
const CACHE = `${PREFIX}${VERSION}`;

const SHELL = ["/", "/app.js", "/wearable-labels.js", "/app.css", "/live-hr.js", "/range-presets.js", "/people-ui.js", "/meeting-actions.js", "/pwa.js", "/install-gate.js", "/ptr.js", "/ptr-logic.js", "/ask-panel.js", "/ask-logic.js", "/ask-panel.css", "/manifest.webmanifest"];
const PASS_THROUGH = /^\/(api|auth|hooks|setup)(\/|\.|$)/;

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      // One by one, and failures are fine: a page behind Cloudflare Access may
      // answer with a redirect, which must never be cached as the app.
      await Promise.all(
        SHELL.map(async (path) => {
          try {
            const res = await fetch(path, { cache: "no-store", credentials: "same-origin", redirect: "manual" });
            if (cacheable(res)) await cache.put(path, res);
          } catch {
            /* offline during install: the first online load fills it */
          }
        }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) {
        if (key.startsWith(PREFIX) && key !== CACHE) await caches.delete(key);
      }
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "version") event.ports[0]?.postMessage({ version: VERSION });
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (PASS_THROUGH.test(url.pathname) || url.pathname === "/sw.js") return;

  if (req.mode === "navigate") {
    // Every app route is the same single page; keep one copy of it under "/".
    event.respondWith(networkFirst(req, "/"));
  } else if (url.pathname.startsWith("/icons/") || url.pathname === "/favicon.ico") {
    event.respondWith(cacheFirst(req));
  } else if (SHELL.includes(url.pathname)) {
    event.respondWith(networkFirst(req, url.pathname));
  }
});

function cacheable(res) {
  return res && res.ok && res.type === "basic" && !res.redirected;
}

async function networkFirst(req, key) {
  const cache = await caches.open(CACHE);
  try {
    // no-cache: always ask the server (a cheap ETag check), never trust the
    // HTTP cache alone, so a deploy is visible on the very next load.
    const res = await fetch(req, req.mode === "navigate" ? undefined : { cache: "no-cache" });
    if (cacheable(res)) cache.put(key, res.clone()).catch(() => {});
    return res;
  } catch (err) {
    const hit = (await cache.match(key)) ?? (await caches.match(key));
    if (hit) return hit;
    throw err;
  }
}

async function cacheFirst(req) {
  const hit = await caches.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (cacheable(res)) {
    const cache = await caches.open(CACHE);
    cache.put(req, res.clone()).catch(() => {});
  }
  return res;
}
