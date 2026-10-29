const assert = require('node:assert/strict');
const path = require('node:path');
const {Document,snapshot} = require(path.resolve(process.argv[2] || __dirname+'/..','Resources/PlaintextWeb/offline.js'));
function setup(record={},api=async()=>({path:'/file.txt',revision:'next'})){
 const records=new Map(),timers=new Map();let next=0;
 const store={put:async value=>{records.set(value.id,structuredClone(value));}};
 const options={store,api,schedule:fn=>{timers.set(++next,fn);return next;},cancel:id=>timers.delete(id)};
 return {doc:new Document({path:'/file.txt',contents:'original',revision:'base',...record},options),records,timers,store,options};
}
async function settled(doc){if(doc.running)await doc.sync();await doc.writes;}
(async()=>{
 let {doc,records,options,store}=setup();doc.edit('offline text');await doc.persist();assert.equal(records.get(doc.id).contents,'offline text');assert.equal(doc.localVersion,1);
 doc=new Document(records.get(doc.id),options);await doc.persist();assert.equal(doc.contents,'offline text');assert(doc.dirty);
 const untitled=setup({path:''});untitled.doc.edit('untitled draft');await untitled.doc.persist();assert.equal(untitled.records.get(untitled.doc.id).contents,'untitled draft');
 let calls=[],release;
 ({doc,records}=setup({},async(op,values)=>{calls.push({op,...values});if(op==='commit')return new Promise(resolve=>release=resolve);return{};}));
 doc.edit('first edit');await doc.requestSave();await new Promise(setImmediate);doc.edit('newer edit');release({path:'/file.txt',revision:'r1'});await settled(doc);
 assert.equal(calls[0].contents,'first edit');assert(doc.dirty);assert.equal(doc.contents,'newer edit');assert.equal(doc.revision,'r1');assert.equal(doc.pendingSave,null);assert(records.get(doc.id).dirty);
 calls=[];
 ({doc}=setup({},async(op,values)=>{calls.push({op,...values});if(calls.length===1)return new Promise(resolve=>release=resolve);return {path:'/file.txt',revision:'r2'};}));
 doc.edit('first');await doc.requestSave();await new Promise(setImmediate);doc.edit('second');await doc.requestSave();release({path:'/file.txt',revision:'r1'});await settled(doc);await doc.sync();
 assert.equal(calls[1].revision,'r1');assert.equal(calls[1].contents,'second');assert.equal(doc.dirty,false);
 const network=Object.assign(Error('down'),{network:true});
 ({doc,records,options}=setup({},async()=>{throw network;}));doc.edit('queued offline');await doc.requestSave();await settled(doc);
 assert.equal(records.get(doc.id).pendingSave.contents,'queued offline');assert(doc.retryTimer);assert(doc.message.includes('Waiting for connection'));
 const restored=new Document(records.get(doc.id),{...options,api:async()=>({path:'/file.txt',revision:'after-reconnect'})});await restored.sync();assert(!restored.pendingSave);assert(!restored.dirty);
 ({doc}=setup({},async(op,values)=>{if(op==='commit')throw network;return {path:'/file.txt',contents:'written',revision:'written-revision'};}));doc.edit('written');await doc.requestSave();await settled(doc);assert(!doc.pendingSave);assert(!doc.dirty);assert.equal(doc.revision,'written-revision');
 ({doc,records}=setup({},async(op)=>{if(op==='commit')throw Error('file changed');return {path:'/file.txt',contents:'someone else',revision:'external'};}));doc.edit('my version');await doc.requestSave();await settled(doc);
 assert(doc.conflict);assert.equal(records.get(doc.id).contents,'my version');assert(!doc.retryTimer);
 let usedRevision;doc.api=async(op,values)=>{usedRevision=values.revision;return{path:'/file.txt',revision:'resolved'};};await doc.resolveConflict('external');await settled(doc);assert.equal(usedRevision,'external');assert(!doc.conflict);
 ({doc,store}=setup());store.put=async()=>{throw Error('Quota exceeded')};doc.edit('keep me');assert.equal(await doc.persist(),false);assert(doc.message.includes('Not saved on this device'));assert.equal(await doc.requestSave(),false);assert.equal(doc.contents,'keep me');
 ({doc,records}=setup());doc.edit('one');const first=doc.persist();doc.edit('two');const second=doc.persist();await Promise.all([first,second]);assert.equal(records.get(doc.id).contents,'two');assert.equal(records.get(doc.id).version,2);
 const a=setup(),b=setup();assert.notEqual(a.doc.id,b.doc.id);
 console.log('PASS local and untitled recovery, durable save queue, reconnect, lost response, conflicts, newer edits, serialized persistence and storage failures');
})().catch(error=>{console.error(error);process.exitCode=1;});
