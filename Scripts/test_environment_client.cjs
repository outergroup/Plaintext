const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const vm = require('node:vm'), assert = require('node:assert/strict'), {spawnSync} = require('node:child_process');
const base = path.resolve(__dirname, '../..');
const codecs = Object.fromEntries(['Files','Plaintext'].map(app => [app,
    vm.runInThisContext('(function(){' + fs.readFileSync(path.join(base,app,'Resources',app+'Web','environment.js'),'utf8') + ';return EnvironmentBinary;})()')]));
const helper = process.argv[2], filesHelper=process.argv[3];
const codec=codecs.Plaintext;
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'environment-binary-'));
const env = {...process.env, XDG_STATE_HOME:path.join(root, 'state'), OUTERSHELLD_API_SOCKET:path.join(root, 'no-daemon')};
function invoke(input, app='Plaintext') {
    const result = spawnSync(app==='Files'?filesHelper:helper, [], {input, env, maxBuffer:24*1024*1024});
    assert.equal(result.status, 0, result.stderr?.toString());
    return result.stdout.buffer.slice(result.stdout.byteOffset, result.stdout.byteOffset + result.stdout.length);
}
function call(op, fields={}, app='Plaintext') {return codecs[app].decode(invoke(codecs[app].encode(op,fields),app),op);}
try {
    const file = path.join(root, 'quoted " café\n.txt');
    fs.writeFileSync(file, 'original ☃\n');
    assert.equal(call('targets').targets[0].id, 'host');
    const listed = call('list', {path:root}, 'Files');
    assert.equal(listed.entries.find(e=>e.path===file).name, path.basename(file));
    let read = call('read', {path:file});
    assert.equal(read.contents, 'original ☃\n');
    call('draft', {path:file, revision:read.revision, contents:'unsaved < & \u2028'});
    read = call('read', {path:file});
    assert.equal(read.dirty, true); assert.equal(read.draftConflict, false);
    assert.equal(read.contents, 'unsaved < & \u2028');
    fs.writeFileSync(file, 'external edit');
    assert.equal(call('read', {path:file}).draftConflict, true);
    assert.throws(()=>call('save', {path:file, revision:read.revision, contents:read.contents}), /changed/);
    const clean = call('read', {path:file, user:'separate'});
    assert.equal(clean.dirty, false); assert.equal(clean.contents, 'external edit');
    const saved = call('save', {path:file, revision:clean.revision, contents:'saved'});
    assert.equal(call('read', {path:file}).dirty, false);
    call('draft', {path:file, revision:saved.revision, contents:'moved draft'});
    const moved = path.join(root, 'moved.txt');
    call('move', {path:file, destination:moved, revision:saved.revision});
    assert.equal(call('read', {path:moved}).contents, 'moved draft');
    const image = path.join(root, 'binary.png'), bytes=Buffer.from([0,255,128,0,1]);
    fs.writeFileSync(image,bytes);
    const preview=call('preview',{path:image},'Files');
    assert.deepEqual(Buffer.from(preview.data),bytes); assert.equal(preview.type,'image/png');
    assert.throws(()=>call('read',{path:image}),/UTF-8/);
    assert.throws(()=>call('save',{path:file},'Files'),/not supported/);
    for (const field of [0,4,8,12,16,24,28,40,44,64,68]) {
        const malformed=codec.encode('read',{path:moved});new DataView(malformed.buffer).setUint32(field,0xffffffff,true);
        assert.throws(()=>codec.decode(invoke(malformed),'read'));
    }
    const response=invoke(codec.encode('read',{path:moved}));
    for (const field of [0,4,8,12,16,20,24,28,40,44]) {
        const malformed=response.slice(0);new DataView(malformed).setUint32(field,0xffffffff,true);
        assert.throws(()=>codec.decode(malformed,'read'));
    }
    for(const size of [0,1,47,48,63]) assert.throws(()=>codec.decode(response.slice(0,size),'read'));
    assert.throws(()=>codec.encode('save',{contents:'\0'}));
    assert.throws(()=>codec.encode('save',{contents:'x'.repeat(4*1024*1024+1)}));
    const drafts=path.join(root,'state/outershell/plaintext-environments');
    const draft=fs.readdirSync(drafts).find(name=>name.endsWith('.oedraft'));
    fs.writeFileSync(path.join(drafts,draft),Buffer.from('corrupt'));
    assert.throws(()=>call('read',{path:moved}),/draft/);
    console.log('PASS: real C helper ↔ browser codec; discovery, listing, raw preview, read/save/conflict, draft recovery/scoping/move, malformed requests and replies');
} finally {fs.rmSync(root,{recursive:true,force:true});}
