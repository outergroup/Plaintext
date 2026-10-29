'use strict';
const cacheName = 'plaintext-shell-v2';
const assets = ['/', '/web/app.css', '/web/environment.js', '/web/offline.js', '/web/app.js'];
self.addEventListener('install', event => {
    event.waitUntil(caches.open(cacheName).then(cache => cache.addAll(assets)));
});
self.addEventListener('activate', event => {
    event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('plaintext-shell-') && key !== cacheName).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
    const url = new URL(event.request.url);
    if (url.origin !== self.location.origin || event.request.method !== 'GET' || url.pathname.startsWith('/api/')) return;
    if (event.request.mode === 'navigate' && ['/', '/index'].includes(url.pathname)) {
        event.respondWith(caches.open(cacheName).then(async cache => (await cache.match('/')) || fetch(event.request)));
    } else if (assets.includes(url.pathname)) {
        event.respondWith(caches.open(cacheName).then(async cache => (await cache.match(url.pathname)) || fetch(event.request)));
    }
});
let updating = null;
async function prepareUpdate(clientID) {
    const page = await self.clients.get(clientID);
    if (!page || page.type !== 'window' || page.visibilityState !== 'visible') return;
    const token = crypto.randomUUID();
    const deadline = Date.now() + 5000;
    let activated = false;
    try {
        const ready = await new Promise(resolve => {
            const channel = new MessageChannel();
            const finish = value => { clearTimeout(timer); channel.port1.close(); resolve(value); };
            const timer = setTimeout(() => finish(false), 5000);
            channel.port1.onmessage = event => finish(event.data?.ready === true);
            page.postMessage({type:'plaintext-update-prepare', token}, [channel.port2]);
        });
        const current = await self.clients.get(clientID);
        if (!ready || Date.now() >= deadline || current?.visibilityState !== 'visible') return;
        await self.skipWaiting();
        activated = true;
    } finally {
        if (!activated) page.postMessage({type:'plaintext-update-abort', token});
    }
}
self.addEventListener('message', event => {
    if (event.data?.type !== 'plaintext-update-request' || !event.source?.id) return;
    if (!updating) updating = prepareUpdate(event.source.id).finally(() => { updating = null; });
    event.waitUntil(updating);
});
