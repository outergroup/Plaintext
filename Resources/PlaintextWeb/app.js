(() => {
'use strict';
const $ = selector => document.querySelector(selector);
const query = new URLSearchParams(location.search);
const drafts = new PlaintextDrafts.Store();
const storageUser = window.outerLoop?.sessionContext?.username || '';
const documents = new Map();
let recoveryWarning = '';
const state = {target:query.get('target') || 'host', targets:[], active:null, replacing:false, pickerPath:'~', pickerSelected:null, pickerVersion:0};
function status(text){$('#status').textContent=text;}
function targetName(target){return state.targets.find(t=>t.id===target)?.name || (target==='host'?'Host':'Unavailable container');}
async function api(operation, values={}, context=state){
 const body=EnvironmentBinary.encode(operation,{target:context.target,...values});
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),10000);
 try{
  let response,buffer;
  try{response=await fetch('/api/environments',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Environment-Request':'1'},body,signal:controller.signal});buffer=await response.arrayBuffer();}
  catch(cause){const error=Error('Waiting for connection.');error.network=true;throw error;}
  if(!response.ok){const error=Error(new TextDecoder().decode(buffer));error.network=response.status>=500;throw error;}
  return EnvironmentBinary.decode(buffer,operation);
 }finally{clearTimeout(timeout);}
}
async function discover(){
 try{const result=await api('targets');state.targets=result.targets;const select=$('#environment');select.replaceChildren(...result.targets.map(t=>{const option=new Option(t.id==='host'?`Host — ${t.name}`:t.name+(t.state==='running'?'':` · ${t.state}`),t.id);option.disabled=t.state!=='running';return option}));if(!state.targets.some(t=>t.id===state.target))select.add(new Option('Unavailable container',state.target));select.value=state.target;$('#environment-errors').textContent=result.errors.map(e=>`${e.runtime}: ${e.error}`).join(' · ');if(state.active)showPath(state.active);else $('#targetLabel').textContent=targetName(state.target);renderDocument()}catch(e){$('#environment-errors').textContent=e.message}
}
function renderDocument(){
 $('#dirty').textContent=state.active?.dirty?'Edited':'';
 $('#review').hidden=!state.active?.conflict;
 $('#editor').disabled=!state.active||state.replacing;
 $('#save').disabled=!state.active||state.replacing;$('#move').disabled=!state.active?.path||state.replacing;
 for(const id of ['new','open','path','location-target'])$('#'+id).disabled=state.replacing;
 $('#download').disabled=!state.active;
 document.title=(state.active?.dirty?'• ':'')+(state.active?(state.active.path.split('/').pop()||'Untitled'):'Plaintext');
}
function showPath(doc){$('#targetLabel').textContent=targetName(doc.target);const label=$('#pathLabel');label.replaceChildren();const parts=doc.path.split('/').filter(Boolean);const filename=document.createElement('strong');filename.textContent=parts.pop()||'Untitled';if(parts.length){const parent=document.createElement('span');parent.className='parent-path';parent.textContent=parts.join(' / ')+' / ';label.append(parent)}label.append(filename);$('#path').title=doc.path||'Untitled';history.replaceState(null,'','?'+new URLSearchParams({file:doc.path,target:doc.target,draft:doc.id}).toString().replace(/%2F/gi,'/'));}
function documentChanged(doc){
 if(state.active!==doc)return;
 const locationKey=JSON.stringify([doc.id,doc.path,doc.target,targetName(doc.target)]);
 if(state.locationKey!==locationKey){state.locationKey=locationKey;showPath(doc);}
 renderDocument();status(doc.message+(recoveryWarning?' · '+recoveryWarning:''));
}
async function createDocument(record, forkIfLocked=true){
 if(documents.has(record.id))return documents.get(record.id);
 let release=null;
 record={...record,id:record.id||crypto.randomUUID()};
 if(navigator.locks){
  const claim=()=>new Promise(resolve=>{
   navigator.locks.request('plaintext-draft-'+record.id,{ifAvailable:true},lock=>{
    if(!lock){resolve(false);return;}
    return new Promise(done=>{release=done;resolve(true);});
   }).catch(()=>resolve(false));
  });
  if(!(await claim())){if(!forkIfLocked)return null;record={...record,id:crypto.randomUUID()};await claim();}
 }else{if(!forkIfLocked)return null;record={...record,id:crypto.randomUUID()};}
 const doc=new PlaintextDrafts.Document(record,{store:drafts,api,changed:documentChanged});
 doc.release=release;documents.set(doc.id,doc);
 await doc.persist();
 return doc;
}
function activate(doc){state.active=doc;state.target=doc.target;$('#editor').value=doc.contents;documentChanged(doc);doc.resume();}
async function replaceDocument(replacement){
 if(state.replacing)return;
 state.replacing=true;renderDocument();
 const previous=state.active;
 try{
  if(previous&&!(await previous.persist()))throw Error(previous.message);
  await replacement();
  if(previous&&previous!==state.active&&!previous.pendingSave){previous.stop();if(previous.running)void previous.running.finally(()=>previous.release?.());else previous.release?.();documents.delete(previous.id);}
 }catch(e){status(e.message);}
 finally{state.replacing=false;renderDocument();}
}
function newDocument(){return replaceDocument(async()=>activate(await createDocument({target:state.active?.target||state.target,user:storageUser})));}
async function localRecords(){
 try{return(await drafts.all()).filter(record=>record.user===storageUser).sort((a,b)=>b.updatedAt-a.updatedAt);}
 catch(e){recoveryWarning='Local recovery unavailable: '+e.message;return [];}
}
async function load(path, context={target:state.target}, draftID=null){
 if(state.active?.path===path&&state.active.target===context.target&&!draftID)return;
 await replaceDocument(async()=>{
  status('Opening…');
  const records=await localRecords();
  const local=draftID?records.find(d=>d.id===draftID&&d.target===context.target):records.find(d=>d.path===path&&d.target===context.target);
  if(local){
   const doc=await createDocument(local);activate(doc);
   if(!doc.dirty&&!doc.pendingSave)void refreshDocument(doc);
   return;
  }
  if(!path){activate(await createDocument({target:context.target,user:storageUser}));return;}
  const result=await api('read',{path},context);
  activate(await createDocument({...context,user:storageUser,path:result.path,contents:result.contents,revision:result.revision,dirty:result.dirty,conflict:result.draftConflict}));
 });
}
async function refreshDocument(doc){
 const version=doc.version;
 try{
  const result=await api('read',{path:doc.path},doc);
  if(doc.version!==version||doc.dirty||doc.pendingSave)return;
  Object.assign(doc,{contents:result.contents,revision:result.revision,dirty:result.dirty,conflict:result.draftConflict});
  await doc.persist();
  if(state.active===doc&&doc.version===version)$('#editor').value=doc.contents;
 }catch(e){doc.networkError=e.network?'Offline copy · Waiting for connection.':e.message;doc.notify();}
}
function ask(title, value=null, action='Save'){
 return new Promise(resolve=>{
  const dialog=document.createElement('dialog'),form=document.createElement('form'),heading=document.createElement('h3'),input=document.createElement('input'),buttons=document.createElement('div');
  dialog.className='path-dialog';form.method='dialog';heading.textContent=title;form.append(heading);
  if(value!==null){input.value=value;input.setAttribute('aria-label',title);input.autofocus=true;form.append(input);}
  for(const [label,result] of [['Cancel','cancel'],[action,'accept']]){const button=document.createElement('button');button.textContent=label;button.value=result;button.type=result==='accept'?'submit':'button';if(result==='cancel')button.onclick=()=>dialog.close('cancel');buttons.append(button);}
  form.append(buttons);dialog.append(form);document.body.append(dialog);
  dialog.addEventListener('close',()=>{const answer=dialog.returnValue==='accept'?(value===null?true:input.value.trim()):null;dialog.remove();resolve(answer);},{once:true});
  dialog.showModal();if(value!==null){input.focus();input.select();}
 });
}
async function save(doc=state.active){
 if(!doc)return false;
 if(doc.conflict){await reviewChanges();return false;}
 let path=doc.path;
 if(!path){path=await ask('Save as','~/Untitled.txt');if(!path)return false;}
 return doc.requestSave(path);
}
function downloadDocument(){
 const doc=state.active;if(!doc)return;
 const url=URL.createObjectURL(new Blob([doc.contents],{type:'text/plain;charset=utf-8'}));
 const link=document.createElement('a');link.href=url;link.download=doc.path.split('/').pop()||'Untitled.txt';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
}
async function recoverDraft(){
 const records=await localRecords();
 const dialog=document.createElement('dialog');dialog.className='recovery-dialog';
 const heading=document.createElement('h3');heading.textContent='Drafts saved on this device';dialog.append(heading);
 const list=document.createElement('div');list.className='recovery-list';
 for(const record of records){
  const button=document.createElement('button');button.textContent=(record.path||'Untitled')+' — '+targetName(record.target)+' · '+new Date(record.updatedAt).toLocaleString()+(record.pendingSave?' · Save queued':record.dirty?' · Edited':'');
  button.onclick=()=>{dialog.close();void load(record.path,{target:record.target},record.id);};list.append(button);
 }
 if(!records.length)list.textContent=recoveryWarning||'No drafts saved on this device yet.';
 const close=document.createElement('button');close.textContent='Close';close.onclick=()=>dialog.close();
 dialog.append(list,close);dialog.onclose=()=>dialog.remove();document.body.append(dialog);dialog.showModal();
}
async function reviewChanges(){
 const doc=state.active;if(!doc?.path)return;
 try{
  const disk=await api('disk',{path:doc.path},doc);
  const dialog=document.createElement('dialog');dialog.className='conflict-dialog';
  const heading=document.createElement('h3');heading.textContent='The file changed elsewhere';
  const comparison=document.createElement('div');comparison.className='comparison';
  for(const [label,text] of [['Your draft',doc.contents],['File on server',disk.contents]]){
   const panel=document.createElement('label');panel.textContent=label;const area=document.createElement('textarea');area.readOnly=true;area.value=text;panel.append(area);comparison.append(panel);
  }
  const actions=document.createElement('div');actions.className='conflict-actions';
  for(const [title,action] of [['Close',()=>{}],['Save a copy…',async()=>{const path=await ask('Save a copy as',doc.path+'.copy');if(path)await doc.saveCopy(path);}],['Replace server file with my draft',()=>doc.resolveConflict(disk.revision)]]){
   const button=document.createElement('button');button.textContent=title;button.onclick=()=>{dialog.close();void action();};actions.append(button);
  }
  dialog.append(heading,comparison,actions);dialog.onclose=()=>dialog.remove();document.body.append(dialog);dialog.showModal();
 }catch(e){status('Your draft is kept on this device. Cannot compare the server file: '+e.message);}
}
$('#editor').addEventListener('input',()=>{if(state.active&&!state.replacing)state.active.edit($('#editor').value);});
$('#editor').addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='s'){e.preventDefault();void save();}else if(e.key==='Tab'){e.preventDefault();const t=e.currentTarget;t.setRangeText('\t',t.selectionStart,t.selectionEnd,'end');t.dispatchEvent(new Event('input'));}});
$('#save').onclick=()=>save();$('#new').onclick=newDocument;
$('#recover').onclick=recoverDraft;$('#download').onclick=downloadDocument;$('#review').onclick=reviewChanges;
$('#move').onclick=async()=>{
 const doc=state.active;if(!doc?.path)return;
 if(doc.dirty||doc.pendingSave){status('Save this file and wait for confirmation before moving it.');return;}
 const destination=await ask('Move or rename file',doc.path,'Move');if(!destination||destination===doc.path)return;
 state.replacing=true;renderDocument();
 try{const result=await api('move',{path:doc.path,destination,revision:doc.revision},doc);doc.path=result.path;await doc.persist();documentChanged(doc);}
 catch(e){status(e.message);}finally{state.replacing=false;renderDocument();}
};
async function pickerLoad(path){
 const version=++state.pickerVersion;state.pickerSelected=null;$('#choose').disabled=true;$('#pickerRows').replaceChildren();$('#pickerPath').textContent='Loading…';
 try{const value=await api('list',{path});if(version!==state.pickerVersion)return;state.pickerPath=value.path;state.pickerSelected=null;$('#choose').disabled=true;$('#pickerPath').textContent=value.path;
 const entries=[...(value.parent?[{name:'..',path:value.parent,directory:true}]:[]),...value.entries];
 $('#pickerRows').replaceChildren(...entries.map(entry=>{const row=document.createElement('div');row.className='picker-row';const icon=document.createElement('span');icon.textContent=entry.directory?'📁':'📄';const text=document.createElement('span');text.textContent=entry.name;row.append(icon,text);row.onclick=()=>{document.querySelectorAll('.picker-row.selected').forEach(r=>r.classList.remove('selected'));row.classList.add('selected');state.pickerSelected=entry;$('#choose').disabled=entry.directory;};row.ondblclick=()=>entry.directory?pickerLoad(entry.path):choose(entry.path);return row;}));
 }catch(e){if(version===state.pickerVersion){$('#pickerRows').replaceChildren();$('#pickerPath').textContent=e.message;}}
}
function openPicker(){state.target=state.active?.target||state.target;$('#environment').value=state.target;if(!$('#picker').open)$('#picker').showModal();const path=state.active?.path;pickerLoad(path&&path.includes('/')?path.slice(0,path.lastIndexOf('/'))||'/':'~');}
function choose(path){const context={target:state.target};$('#picker').close();load(path,context);}
$('#choose').onclick=e=>{e.preventDefault();if(state.pickerSelected&&!state.pickerSelected.directory)choose(state.pickerSelected.path);};
$('#open').onclick=openPicker;$('#path').onclick=openPicker;$('#location-target').onclick=openPicker;
$('#environment').onchange=()=>{state.target=$('#environment').value;pickerLoad('~');};
$('#environment-refresh').onclick=discover;
$('#picker').addEventListener('close',()=>{state.pickerVersion++;state.target=state.active?.target||state.target;});
$('#document-menu').addEventListener('click',e=>{if(e.target.closest('button'))$('#document-menu').open=false;});
document.addEventListener('pointerdown',e=>{if(!e.target.closest('#document-menu'))$('#document-menu').open=false;});
window.addEventListener('beforeunload',e=>{if([...documents.values()].some(doc=>doc.localError||doc.localVersion<doc.version)){e.preventDefault();e.returnValue='';}});
window.addEventListener('online',()=>{for(const doc of documents.values())doc.resume();void discover();});
document.addEventListener('visibilitychange',()=>{for(const doc of documents.values()){void doc.persist();if(!document.hidden)doc.resume();}});
window.addEventListener('pagehide',()=>{for(const doc of documents.values()){void doc.persist();doc.stop();}});
window.addEventListener('pageshow',event=>{if(event.persisted)for(const doc of documents.values())doc.resume();});
async function prepareOfflineShell(){
 if(!('serviceWorker' in navigator)){recoveryWarning='Offline reload is unavailable in this browser';return;}
 try{await navigator.serviceWorker.register('/sw.js',{scope:'/'});await navigator.serviceWorker.ready;}
 catch(e){recoveryWarning='Offline reload unavailable: '+e.message;}
 state.active?.notify();
}
$('#editor').disabled=true;renderDocument();
void prepareOfflineShell();void discover();
async function boot(){
 await load(query.get('file')||'',{target:state.target},query.get('draft'));
 for(const record of await localRecords()){
  if(record.pendingSave&&!record.conflict&&!documents.has(record.id)){
   const doc=await createDocument(record,false);
   doc?.resume();
  }
 }
}
void boot();
})();
