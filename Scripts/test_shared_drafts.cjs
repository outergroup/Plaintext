const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {spawn} = require('node:child_process');
const {Readable} = require('node:stream');
const {Document, Notifications, snapshot} = require('../Resources/PlaintextWeb/offline.js');
const binary = require('node:vm').runInThisContext(fs.readFileSync(path.join(__dirname,'../Resources/PlaintextWeb/environment.js'),'utf8')+';EnvironmentBinary');
const tick = () => new Promise(setImmediate);
async function until(condition) {
    const end = Date.now()+5000;
    while (!condition()) { assert(Date.now()<end, 'timed out'); await new Promise(resolve=>setTimeout(resolve,10)); }
}
(async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(),'plaintext-shared-'));
    const socketPath = path.join(directory,'server.sock'), file = path.join(directory,'document');
    fs.writeFileSync(file,'original');
    const backend = spawn(process.argv[2],['--socket-path',socketPath],{env:{...process.env,XDG_STATE_HOME:path.join(directory,'state')},stdio:'ignore'});
    const streams = [], docs = [];
    function request(route, body, signal) {
        return new Promise((resolve,reject) => {
            const request = http.request({socketPath,path:route,method:'POST',headers:{'X-Environment-Request':'1','Content-Length':body.length},signal},resolve);
            request.on('error',reject); request.end(body);
        });
    }
    async function api(operation, values={}) {
        const response = await request('/api/environments',binary.encode(operation,values));
        const chunks=[];for await (const chunk of response) chunks.push(chunk);
        const bytes=Buffer.concat(chunks);return binary.decode(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length),operation);
    }
    async function client(record) {
        const current = record || {...await api('state',{path:file}),remoteVersion:0};
        const records=[];
        const doc = new Document(current,{api,store:{put:async value=>records.push(value)},schedule:()=>1,cancel:()=>{}});
        doc.setWatching(true); docs.push(doc);
        const stream=new Notifications({open:async signal=>{
            const response=await request('/api/watch',binary.encode('disk',{path:file}),signal);
            return {ok:response.statusCode===200,body:Readable.toWeb(response)};
        },changed:()=>{void doc.refresh();}});
        streams.push(stream);void stream.connect();return {doc,records,stream};
    }
    try {
        await until(()=>fs.existsSync(socketPath));
        const a=await client(), b=await client();
        a.doc.edit('draft one');await a.doc.sync();
        await until(()=>b.doc.contents==='draft one');
        assert(b.doc.dirty); assert.equal(b.doc.remoteVersion,b.doc.version); assert.equal(fs.readFileSync(file,'utf8'),'original');
        b.doc.edit('draft two');await b.doc.sync();await until(()=>a.doc.contents==='draft two');
        assert(a.doc.dirty);assert.equal(a.records.at(-1).contents,'draft two');
        await b.doc.requestSave();await b.doc.sync();await until(()=>!a.doc.dirty);
        assert.equal(a.doc.contents,'draft two');assert.equal(fs.readFileSync(file,'utf8'),'draft two');
        a.doc.edit('from a');b.doc.edit('from b');
        await a.doc.sync();await b.doc.sync();
        assert(b.doc.conflict);assert.equal(b.doc.contents,'from b');
        assert.equal((await api('state',{path:file})).contents,'from a');
        const shared=await api('state',{path:file});
        await b.doc.resolveConflict(shared.diskRevision,shared.draftRevision);await b.doc.sync();
        await until(()=>a.doc.contents==='from b'&&!a.doc.dirty);
        assert.equal(fs.readFileSync(file,'utf8'),'from b');
        b.stream.stop();b.doc.stop();
        a.doc.edit('while disconnected');await a.doc.sync();
        const restored=await client(snapshot(b.doc));await restored.doc.refresh();
        assert.equal(restored.doc.contents,'while disconnected');assert(restored.doc.dirty);
        // A save made during an in-flight publish must use the acknowledged draft revision.
        let release, entered=false;
        const realApi=a.doc.api;
        a.doc.api=async(op,values)=>{const result=await realApi(op,values);if(op==='publish'){entered=true;await new Promise(resolve=>release=resolve);}return result;};
        a.doc.edit('publish then save');const publishing=a.doc.sync();await until(()=>entered);
        await a.doc.requestSave();release();await publishing;await a.doc.sync();
        assert(!a.doc.conflict&&!a.doc.dirty);assert.equal(fs.readFileSync(file,'utf8'),'publish then save');a.doc.api=realApi;
        // Recover an acknowledgment lost after the server accepted a draft.
        a.doc.api=async(op,values)=>{const result=await realApi(op,values);if(op==='publish')throw Object.assign(Error('lost response'),{network:true});return result;};
        a.doc.edit('lost publish response');await a.doc.sync();assert(!a.doc.conflict);assert.equal(a.doc.remoteVersion,a.doc.version);
        await until(()=>restored.doc.contents==='lost publish response');
        a.doc.api=realApi;
        let finishPublish; entered=false;
        a.doc.api=async(op,values)=>{const result=await realApi(op,values);if(op==='publish'){entered=true;await new Promise(resolve=>finishPublish=resolve);}return result;};
        a.doc.edit('copy while publishing');const oldPublish=a.doc.sync();await until(()=>entered);
        const copy=path.join(directory,'copy');await a.doc.saveCopy(copy);finishPublish();await oldPublish;await a.doc.sync();
        assert.equal(fs.readFileSync(copy,'utf8'),'copy while publishing');
        assert.equal((await api('state',{path:file})).contents,'copy while publishing');
        const discardFile=path.join(directory,'discard');fs.writeFileSync(discardFile,'saved version');
        const base=await api('state',{path:discardFile});
        const published=await api('publish',{path:discardFile,contents:'shared draft',revision:base.revision,draftRevision:base.draftRevision});
        await assert.rejects(api('discard',{path:discardFile,revision:base.revision,draftRevision:'missing'}),error=>error.conflict);
        assert.equal((await api('state',{path:discardFile})).contents,'shared draft');
        fs.writeFileSync(discardFile,'new saved version');
        await assert.rejects(api('discard',{path:discardFile,revision:base.revision,draftRevision:published.draftRevision}),error=>error.conflict);
        const latest=await api('disk',{path:discardFile});const beforeDiscard=fs.statSync(discardFile).mtimeMs;
        const discardedRecords=[];
        const discarded=new Document({...base,contents:'my conflicting draft',dirty:true,conflict:true,pendingSave:{contents:'my conflicting draft'}},
            {api,store:{put:async record=>discardedRecords.push(record)},schedule:()=>1,cancel:()=>{}});
        docs.push(discarded);
        await discarded.discardConflict(latest.revision,published.draftRevision);
        assert.equal(discarded.contents,'new saved version');assert(!discarded.dirty&&!discarded.conflict&&!discarded.pendingSave);
        assert.equal(discardedRecords.at(-1).contents,'new saved version');
        const afterDiscard=await api('state',{path:discardFile});
        assert.equal(afterDiscard.contents,'new saved version');assert(!afterDiscard.dirty);assert.equal(afterDiscard.draftRevision,'missing');
        assert.equal(fs.statSync(discardFile).mtimeMs,beforeDiscard);
        const largeFile=path.join(directory,'large');fs.writeFileSync(largeFile,'');
        const empty=await api('state',{path:largeFile});
        const large='x'.repeat(4*1024*1024);
        const largeDraft=await api('publish',{path:largeFile,contents:large,revision:empty.revision,draftRevision:empty.draftRevision});
        const largeState=await api('state',{path:largeFile});
        assert.equal(largeState.contents.length,large.length);assert.equal(largeState.draftRevision,largeDraft.draftRevision);
        console.log('PASS real clients and notification streams: shared Edited state, bidirectional drafts, save clears Edited, conflicts preserve both drafts, explicit resolution, revision-checked discard without rewriting the file, offline catch-up, publish/save race, lost acknowledgment, Save a Copy');
    } finally {
        streams.forEach(stream=>stream.stop());docs.forEach(doc=>doc.stop());backend.kill();
        await new Promise(resolve=>backend.once('exit',resolve));fs.rmSync(directory,{recursive:true,force:true});
    }
})().catch(error=>{console.error(error);process.exitCode=1;});
