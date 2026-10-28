const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync((process.argv[2]||require('node:path').resolve(__dirname,'..'))+'/Resources/PlaintextWeb/app.js','utf8');
const replacement=source.slice(source.indexOf('async function replaceDocument('),source.indexOf('function newDocument('));
function setup(){
 const events=[];
 const previous={id:'original',persist:async()=>{events.push('persist');return true;},stop(){events.push('stop');},release(){events.push('release');}};
 const context={state:{active:previous,replacing:false},documents:new Map([[previous.id,previous]]),renderDocument(){},status:message=>events.push(message)};
 vm.createContext(context);vm.runInContext(replacement,context);return{context,previous,events};
}
(async()=>{
 let {context:c,previous,events}=setup();await c.replaceDocument(async()=>{events.push('replace');c.state.active={id:'next'};});assert.deepEqual(events,['persist','replace','stop','release']);assert(!c.documents.has(previous.id));
 ({context:c,previous,events}=setup());previous.persist=async()=>false;previous.message='storage failed';await c.replaceDocument(()=>{throw Error('must not replace')});assert.equal(c.state.active,previous);assert(events.includes('storage failed'));
 ({context:c,previous,events}=setup());previous.pendingSave={contents:'queued'};await c.replaceDocument(()=>{c.state.active={id:'next'};});assert(c.documents.has(previous.id));assert(!events.includes('stop'));
 ({context:c,previous,events}=setup());let finish;const first=c.replaceDocument(()=>new Promise(resolve=>finish=resolve));await new Promise(setImmediate);await c.replaceDocument(()=>{throw Error('concurrent replacement')});finish();await first;assert(!c.state.replacing);
 ({context:c,previous,events}=setup());await c.replaceDocument(()=>{throw Error('read failed')});assert.equal(c.state.active,previous);assert(!events.includes('stop'));
 console.log('PASS single-file replacement persists locally, protects storage failures, retains queued saves and blocks concurrent replacement');
})().catch(e=>{console.error(e);process.exitCode=1;});
