const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../Resources/PlaintextWeb/app.js'),'utf8');
const state={active:null,target:'host',replacing:false};
const documents=new Map(),stored=new Map(),entries=[],messages=[];
const elements=new Map();
let message='',created=0,reads=0,delayRead=null;
const location={search:'',pathname:'/'};
const updateURL=url=>{location.search=new URL(url,'https://example.test').search;};
const context=vm.createContext({
 URLSearchParams,Promise,state,documents,location,updateFrozen:false,storageUser:'test',
 history:{pushState:(_,__,url)=>{entries.push(url);updateURL(url);},replaceState:(_,__,url)=>{if(entries.length)entries[entries.length-1]=url;updateURL(url);}},
 window:{addEventListener(){},scrollTo(){}},
 $:selector=>{if(!elements.has(selector))elements.set(selector,{open:false,value:'',blur(){},close(){this.open=false;}});return elements.get(selector);},
 restoreRecentFile(){},showStartOverlay(){},renderDocument(){},status:text=>{message=text;messages.push(text);},updateFileNotifications(){},renderRecentFiles:async()=>{},
 localRecords:async()=>Array.from(stored.values()),
 api:async(_,values)=>{reads++;if(delayRead)await delayRead;return {path:values.path,contents:'File contents',revision:'1'};},
 createDocument:async record=>{
  if(documents.has(record.id))return documents.get(record.id);
  const doc={...record,id:record.id||String(++created),path:record.path||'',contents:record.contents||'',setWatching(){},persist:async()=>{stored.set(doc.id,{...doc});return true;}};
  documents.set(doc.id,doc);stored.set(doc.id,{...doc});return doc;
 },
 activate:doc=>{state.active?.setWatching(false);state.active=doc;state.target=doc.target;}
});
const section=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
vm.runInContext(section('function documentURL(','function showPath(')+section('let navigationVersion=','async function localRecords(')+section('async function resolveDocument(','async function save('),context);
(async()=>{
 const go=(route,mode)=>context.navigateRoute(route,mode);
 for(const choose of [()=>context.load('/initial.txt'),()=>context.newDocument()]){
  state.active=null;entries.length=0;entries.push('/outer-shell','/');updateURL('/');
  await choose();
  assert.equal(entries.length,2,'The startup choice must replace the initial entry');
  assert.equal(entries[0],'/outer-shell');
  assert.ok(entries[1].includes('draft='));
  await context.newDocument();
  assert.equal(entries.length,3,'Later choices must add a history entry');
 }
 state.active=null;documents.clear();stored.clear();entries.length=0;created=0;reads=0;
 await go(null,'replace');
 const route={path:'/example.txt',target:'host'};
 await go(route);const original=state.active;
 original.contents='Unsaved edit';
 for(let i=0;i<5;i++){
  await go(null,'replace');assert.equal(state.active,null);
  await go(route);assert.equal(state.active,original);assert.equal(state.active.contents,'Unsaved edit');
 }
 assert.equal(reads,1);assert.equal(created,1);
 await go(null,'replace');await go({...route,draftID:original.id},'replace');assert.equal(state.active,original);
 await context.newDocument();const first=state.active;
 await go(null,'replace');messages.length=0;
 await context.newDocument();assert.notEqual(state.active.id,first.id);
 assert.ok(!messages.includes('Opening…'),'Dismissing the start panel into a blank draft must not flash a loading status');
 let release;delayRead=new Promise(resolve=>{release=resolve;});
 const pending=go({path:'/slow.txt',target:'host'});
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(message,'Opening…');
 const latest=go(null,'replace');release();await pending;await latest;
 assert.equal(state.active,null);assert.equal(location.search,'');assert.equal(state.replacing,false);
 delayRead=null;
 await go(route);original.persist=async()=>false;original.message='Draft storage failed';
 await go(null,'replace');assert.equal(state.active,original);assert.equal(message,'Draft storage failed');
 console.log('PASS repeated recent opens reuse the draft; Back/Forward, fresh New, superseded navigation, and persistence failure');
})().catch(error=>{console.error(error);process.exitCode=1;});
