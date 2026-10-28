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
