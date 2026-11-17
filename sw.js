/* v2611172 · VOY™ 서비스워커 — 앱 설치 + 새 글 알림(웹 푸시) + 아이콘 배지
   데이터는 캐시하지 않고 항상 최신으로 불러옵니다. */
const META = 'voy-meta';
const SW_VER = '2611172';
async function getCount() { const c = await caches.open(META); const r = await c.match('/__badge'); return r ? +(await r.text()) || 0 : 0; }
async function getMode() { try { const c = await caches.open(META); const r = await c.match('/__mode'); return r ? await r.text() : 'sound'; } catch (e) { return 'sound'; } }   // 'quiet' = 소리·진동 없이
async function setCount(n) { const c = await caches.open(META); await c.put('/__badge', new Response(String(n))); }
async function applyBadge(n) {   // 숫자 표시만 담당 (지우기는 앱 화면이 열릴 때 페이지가 처리)
  try { if (n > 0 && self.navigator.setAppBadge) await self.navigator.setAppBadge(n); } catch (e) {}
}

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('fetch', e => {
  if (e.request.mode !== 'navigate') return;
  e.respondWith(fetch(e.request).catch(() => new Response(
    '<meta charset="utf-8"><meta name="viewport" content="width=device-width"><div style="font-family:sans-serif;padding:48px 24px;text-align:center"><h3>오프라인 상태입니다</h3><p>인터넷 연결을 확인한 뒤 다시 열어주세요.</p></div>',
    { headers: { 'Content-Type': 'text/html; charset=utf-8' } })));
});

/* 새 글 푸시 수신 → 🔔 알림 + 아이콘 배지 숫자 */
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (er) { d = { body: e.data && e.data.text() }; }
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    wins.forEach(w => { try { w.postMessage({ type: 'voy-push', data: d }); } catch (er) {} });   // 앱 화면에 '알림 도착' 알림 (알림 점검 도우미용)
    const visible = wins.some(w => w.visibilityState === 'visible');
    if (d.test) {   // 알림 점검용 테스트: 앱을 보고 있어도 항상 표시
      await self.registration.showNotification(d.title || '🔔 VOY™ 테스트', { body: d.body || '', icon: 'icons/voy-192.png', badge: 'icons/badge-bell.png', tag: 'voy-test-' + Date.now(), data: { url: d.url || './' } });
      return;
    }
    const n = visible ? 0 : (await getCount()) + 1;
    await setCount(n); await applyBadge(n);
    if (visible) return;   // 앱을 보고 있는 중이면 알림 생략
    const quiet = (await getMode()) === 'quiet';
    await self.registration.showNotification(d.title || '🔔 VOY™ 새 글이 올라왔어요', {
      body: d.body || '새 글을 확인해보세요',
      silent: quiet,                          // 조용히: 소리·진동 없이 알림창 + 아이콘 숫자만
      ...(quiet ? {} : { vibrate: [180, 80, 180] }),
      icon: 'icons/voy-192.png',
      badge: 'icons/badge-bell.png',          // 안드로이드 상단 상태표시줄의 종 모양
      tag: 'voy-post-' + ((d.url || '').match(/post\/(\d+)/)?.[1] || Date.now()),   // 글마다 다른 태그 → 알림이 쌓여 아이콘 숫자가 1→2→3 증가
      data: { url: d.url || './#/feed' }
    });
  })());
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL(e.notification.data && e.notification.data.url || './', self.registration.scope).href;
  e.waitUntil((async () => {
    await setCount(0);
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) { if (w.url.startsWith(self.registration.scope)) { await w.focus(); try { await w.navigate(url); } catch (er) {} return; } }
    await self.clients.openWindow(url);
  })());
});

self.addEventListener('message', e => {
  if (e.data && e.data.type === 'ver') { try { e.source && e.source.postMessage({ type: 'sw-ver', v: SW_VER }); } catch (er) {} return; }
  // 화면(페이지)이 직접 아이콘 배지를 지우므로 여기서는 카운트만 초기화
  if (e.data && e.data.type === 'clear-badge') e.waitUntil((async () => {
    await setCount(0);
    // 안드로이드 홈 아이콘 숫자는 '알림창에 남은 알림 수' → 남은 VOY 알림을 모두 닫아 숫자 제거
    try { (await self.registration.getNotifications()).forEach(n => { if (/^voy-post-/.test(n.tag || '')) n.close(); }); } catch (er) {}   // 새 글 알림만 닫음 (테스트 알림 유지)
    try { if (self.navigator.clearAppBadge) await self.navigator.clearAppBadge(); } catch (er) {}
  })());
});
