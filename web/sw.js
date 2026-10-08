// 離線快取（service worker）。建置後由 tool/make_sw.py 填入版本與檔案清單。
// - 安裝時先把 APP 需要的檔案全部存起來，之後沒有網路也能開
// - 有新版本時：新的快取裝好後立即接手，頁面顯示「重新載入」
// - selftest/（自我檢查的標準答案）不快取，每次都上網抓
const VERSION = '__VERSION__';
const ASSETS = __ASSETS__;
const CACHE = 'crane-' + VERSION;

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then((cache) => cache.addAll(ASSETS.map((a) => new Request(a, { cache: 'reload' }))))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('crane-') && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.indexOf('/selftest/') >= 0) return;

  if (req.mode === 'navigate') {
    // 開啟 APP：用快取的 index.html（離線也能開）；快取沒有時才上網
    event.respondWith(
      caches.open(CACHE).then((cache) =>
        cache.match('index.html').then((hit) => hit || fetch(req)),
      ).catch(() => fetch(req)),
    );
    return;
  }
  event.respondWith(
    caches.open(CACHE).then((cache) =>
      cache.match(req, { ignoreSearch: true }).then((hit) => {
        if (hit) return hit;
        return fetch(req).then((res) => {
          if (res.ok && res.type === 'basic') cache.put(req, res.clone());
          return res;
        });
      }),
    ),
  );
});
