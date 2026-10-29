const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const root=process.argv[2]||path.join(__dirname,'../Resources/PlaintextWeb');
const {ShellUpdates}=require(path.join(root,'offline.js'));
const tick=()=>new Promise(setImmediate);
class Events {
 constructor(values={}){Object.assign(this,values);this.listeners={};}
 addEventListener(type,fn){(this.listeners[type]??=[]).push(fn);}
 emit(type,event={}){for(const fn of this.listeners[type]||[])fn(event);}
}
function page({controller={},ready=true}={}){
 const timers=new Map();let serial=0,reloads=0,releases=0,prepares=0,checks=0;
 const waiting=new Events({postMessage:message=>messages.push(message)}),messages=[];
 const registration=new Events({waiting,update:async()=>{checks++;}});
 const workers=new Events({controller,register:async()=>registration});
 const update=new ShellUpdates({workers,prepare:async()=>{prepares++;return ready;},release:()=>releases++,reload:()=>reloads++,
  schedule:(fn,delay)=>{timers.set(++serial,{fn,delay});return serial;},cancel:id=>timers.delete(id),now:()=>100});
 return {update,workers,registration,waiting,messages,timers,setReady:value=>{ready=value;},counts:()=>({reloads,releases,prepares,checks})};
}
async function workerCase({answers=[true,true],hidden=false,hideDuringPreparation=false}={}){
 const handlers={},timers=new Map(),sent=[];let skipped=0,serial=0,lists=0,closed=0;
 const pages=answers.map((answer,index)=>({id:String(index),type:'window',visibilityState:hidden||index>0?'hidden':'visible',postMessage(message,ports){
  sent.push(message);
  if(ports&&answer!==null)queueMicrotask(()=>ports[0].peer.onmessage({data:{ready:answer}}));
 }}));
 class Channel{constructor(){this.port1={close(){closed++;}};this.port2={peer:this.port1};}}
 const context=vm.createContext({URL,Promise,Date,crypto:require('node:crypto').webcrypto,MessageChannel:Channel,
  setTimeout:(fn)=>{timers.set(++serial,fn);return serial;},clearTimeout:id=>timers.delete(id),
  self:{location:{origin:'https://example.test'},addEventListener:(type,fn)=>handlers[type]=fn,
   clients:{get:async id=>{lists++;const page=pages.find(p=>p.id===id);return hideDuringPreparation&&lists>1?{...page,visibilityState:'hidden'}:page;}},skipWaiting:async()=>{skipped++;}}});
 vm.runInContext(fs.readFileSync(path.join(root,'sw.js'),'utf8'),context);
 let pending;
 const event={source:{id:'0'},data:{type:'plaintext-update-request'},waitUntil:value=>{pending=value;}};
 handlers.message(event);handlers.message(event);
 await tick();
 for(const fn of [...timers.values()])fn();
 await pending;
 return {skipped,sent,closed};
}
(async()=>{
 const p=page();await p.update.start();assert.equal(p.counts().checks,1);
 p.update.check();assert.equal(p.counts().checks,1);
 let response;
 await p.update.message({data:{type:'plaintext-update-prepare',token:'one'},source:p.waiting,ports:[{postMessage:value=>response=value,close(){}}]});
 assert.equal(response.ready,true);assert.equal(p.counts().reloads,0);
 p.workers.controller={};p.workers.emit('controllerchange');await tick();
 p.workers.emit('controllerchange');await tick();assert.equal(p.counts().reloads,1);
 const first=page({controller:null});await first.update.start();first.workers.controller={};first.workers.emit('controllerchange');await tick();assert.equal(first.counts().reloads,0);
 const fail=page({ready:false});await fail.update.start();
 await fail.update.message({data:{type:'plaintext-update-prepare',token:'fail'},source:fail.waiting,ports:[{postMessage:value=>response=value,close(){}}]});
 assert.equal(response.ready,false);assert.equal(fail.counts().releases,1);
 fail.workers.controller={};fail.workers.emit('controllerchange');await tick();assert.equal(fail.counts().reloads,0);
 fail.setReady(true);await fail.update.finish();assert.equal(fail.counts().reloads,1);
 const lease=page();await lease.update.start();
 await lease.update.message({data:{type:'plaintext-update-prepare',token:'lease'},source:lease.waiting,ports:[{postMessage(){},close(){}}]});
 [...lease.timers.values()].find(timer=>timer.delay===10000).fn();assert.equal(lease.counts().releases,1);
 const late=page();await late.update.start();let finish;
 late.update.prepare=()=>new Promise(resolve=>finish=resolve);
 const preparing=late.update.message({data:{type:'plaintext-update-prepare',token:'late'},source:late.waiting,ports:[{postMessage:value=>response=value,close(){}}]});
 late.update.unlock();finish(true);await preparing;assert.equal(response.ready,false);
 const success=await workerCase();assert.equal(success.skipped,1);assert.equal(success.closed,1);assert.equal(success.sent.filter(m=>m.type==='plaintext-update-abort').length,0);
 for(const options of [{answers:[false,true]},{answers:[null,true]},{hideDuringPreparation:true}]){
  const result=await workerCase(options);assert.equal(result.skipped,0);assert.equal(result.sent.filter(m=>m.type==='plaintext-update-abort').length,1);
 }
 for(const answer of [false,null]){
  const result=await workerCase({answers:[true,answer]});assert.equal(result.skipped,1);
  assert.equal(result.sent.filter(m=>m.type==='plaintext-update-prepare').length,1);
 }
 assert.equal((await workerCase({hidden:true})).skipped,0);
 const background=page({ready:false});await background.update.start();
 background.workers.controller={};background.workers.emit('controllerchange');await tick();
 assert.equal(background.counts().reloads,0,'An unprepared background editor must keep running');
 background.setReady(true);await background.update.finish();
 assert.equal(background.counts().reloads,1,'Each resumed editor checkpoints before its own reload');
 const source=fs.readFileSync(path.join(root,'app.js'),'utf8');
 const editor={selectionStart:2,selectionEnd:4,selectionDirection:'forward',scrollLeft:3,focus(){},setSelectionRange(){}};
 let persisted=0,resumed=0,reloaded=0,saveOK=true,releaseWrite;
 const doc={id:'draft',composing:false,stop(){},resume(){resumed++;},persist:async()=>{persisted++;if(releaseWrite)await releaseWrite.promise;return saveOK;}};
 const documents=new Map([['draft',doc]]),store=new Map();
 const context=vm.createContext({Date,Promise,JSON,PlaintextDrafts:{ShellUpdates},documents,state:{active:doc,replacing:false},
  document:{body:{inert:false},activeElement:editor,querySelector:()=>null,addEventListener(){}},
  window:{scrollX:0,scrollY:20,addEventListener(){},scrollTo(){}},location:{href:'https://example.test/?draft=draft',reload:()=>reloaded++},
  navigator:{},$:()=>editor,fileNotifications:null,updateFileNotifications(){},status(){},
  sessionStorage:{setItem:(key,value)=>store.set(key,value),getItem:key=>store.get(key),removeItem:key=>store.delete(key)}});
 vm.runInContext(source.slice(source.indexOf('let shellUpdates='),source.indexOf("$('#editor').disabled=true;renderDocument();",source.indexOf('let shellUpdates='))),context);
 assert.equal(await context.checkpointForUpdate(),false);
 vm.runInContext('bootFinished=true',context);doc.composing=true;assert.equal(await context.checkpointForUpdate(),false);doc.composing=false;
 context.document.querySelector=selector=>selector==='dialog[open]'?{id:'start-overlay'}:null;
 assert.equal(await context.checkpointForUpdate(),true,'The nonmodal Open popover must not block an idle update');
 context.releaseUpdate();resumed=0;store.clear();
 context.document.querySelector=()=>({id:'picker'});
 assert.equal(await context.checkpointForUpdate(),false,'A file picker must defer updates');
 context.document.querySelector=()=>null;
 vm.runInContext('lastInteraction=Date.now()',context);assert.equal(await context.checkpointForUpdate(),false);vm.runInContext('lastInteraction=0',context);
 releaseWrite={};releaseWrite.promise=new Promise(resolve=>releaseWrite.resolve=resolve);
 const checkpoint=context.checkpointForUpdate();await tick();assert.equal(context.document.body.inert,true);assert.equal(store.size,0);
 releaseWrite.resolve();assert.equal(await checkpoint,true);releaseWrite=null;
 const saved=JSON.parse([...store.values()][0]);assert.equal(saved.id,'draft');assert.equal(saved.start,2);assert.equal(saved.y,20);
 context.releaseUpdate();assert.equal(context.document.body.inert,false);assert.equal(resumed,1);
 saveOK=false;assert.equal(await context.checkpointForUpdate(),false);assert.equal(context.document.body.inert,false);
 saveOK=true;releaseWrite={};releaseWrite.promise=new Promise(resolve=>releaseWrite.resolve=resolve);
 const cancelled=context.checkpointForUpdate();context.releaseUpdate();releaseWrite.resolve();assert.equal(await cancelled,false);
 assert.equal(reloaded,0);
 console.log('PASS update discovery, throttling, first install, checkpoint-before-reload, save failures, leases, late replies, foreground activation, suspended tabs, per-tab checkpoint protection, typing/composition and editor restoration checkpoint');
})().catch(error=>{console.error(error);process.exitCode=1;});
