const assert = require('node:assert/strict');
const {Document, Notifications} = require('../Resources/PlaintextWeb/offline.js');
const tick = () => new Promise(setImmediate);
function setup(api) {
    const records = [], timers = new Map(); let next = 0;
    const doc = new Document({path:'/file', contents:'original', revision:'r0'}, {
        api, store:{put:async value => records.push(value)},
        schedule:fn => { timers.set(++next, fn); return next; }, cancel:id => timers.delete(id)
    });
    doc.setWatching(true);
    return {doc, records, timers};
}
(async () => {
    let disk = {contents:'original', revision:'r0',draftRevision:'missing',dirty:false}, reads = 0;
    const api = async (operation, values) => {
        if (operation === 'state') { reads++; return {...disk}; }
        if (operation === 'commit') { disk = {contents:values.contents, revision:'r1',draftRevision:'missing',dirty:false}; return {...disk}; }
        return {};
    };
    const a = setup(api), b = setup(api);
    a.doc.edit('saved elsewhere'); await a.doc.requestSave(); await tick(); await a.doc.sync();
    await b.doc.refresh();
    assert.equal(b.doc.contents, 'saved elsewhere'); assert.equal(b.doc.dirty, false);
    assert.equal(b.records.at(-1).contents, 'saved elsewhere'); assert.equal(b.timers.size, 0);
    const before = reads; await tick(); assert.equal(reads, before);
    for (const field of ['dirty', 'pendingSave', 'conflict', 'composing']) {
        const {doc} = setup(api); doc[field] = true; if (field === 'dirty') doc.remoteVersion = -1;
        await doc.refresh(); assert.equal(doc.contents, 'original'); assert.equal(reads, before);
    }
    for (const invalidate of [doc => doc.edit('my edit'), doc => doc.stop(), doc => doc.setWatching(false), doc => {doc.path='/other';}]) {
        let resolve; const {doc} = setup(() => new Promise(done => resolve = done));
        const pending = doc.refresh(); invalidate(doc); resolve({...disk}); await pending;
        assert.notEqual(doc.contents, disk.contents);
    }
    let releases = [], calls = 0;
    const {doc} = setup(() => { calls++; return new Promise(resolve => releases.push(resolve)); });
    const pending = doc.refresh(); void doc.refresh(); void doc.refresh();
    assert.equal(calls, 1); releases.shift()({contents:'first', revision:'first'}); await pending; await tick();
    assert.equal(calls, 2); releases.shift()({contents:'latest', revision:'latest'}); await tick();
    assert.equal(doc.contents, 'latest');
    let notifications = 0, retries = [], opens = 0;
    const stream = new Notifications({
        open:async () => { opens++; return {ok:true, body:new ReadableStream({start(controller) {
            for (const text of ['{"cha', 'nged":true}\n\n', '{"changed":true}\n']) controller.enqueue(new TextEncoder().encode(text));
            controller.close();
        }})}; },
        changed:() => notifications++, schedule:(fn, delay) => { retries.push({fn, delay}); return 1; }, cancel:() => {}
    });
    await stream.connect(); assert.equal(notifications, 2); assert.equal(opens, 1);
    assert.equal(retries[0].delay, 1000); stream.stop(); retries[0].fn(); await tick(); assert.equal(opens, 1);
    console.log('PASS clean cross-device refresh, durable updates, dirty/composition protection, stale response rejection, event coalescing, no refresh timers, stream framing and reconnect cancellation');
})().catch(error => { console.error(error); process.exitCode = 1; });
