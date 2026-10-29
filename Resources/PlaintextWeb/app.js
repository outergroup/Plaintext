(() => {
'use strict';
const $ = selector => document.querySelector(selector);
const query = new URLSearchParams(location.search);
const drafts = new PlaintextDrafts.Store();
const storageUser = window.outerLoop?.sessionContext?.username || '';
const documents = new Map();
let recoveryWarning = '';
let movingDocument=null;
const state = {target:query.get('target') || 'host', targets:[], active:null, replacing:false, pickerPath:'~', pickerSelected:null, pickerVersion:0};
function status(text){$('#status').textContent=text;$('#start-overlay-status').textContent=$('#start-overlay').open?text:'';}
function configurePopoverDismissal(){
 const panels=[$('#start-overlay'),$('#document-menu'),$('#document-info')].filter(Boolean);
 let dismissing=false;
 function consume(event){event.preventDefault();event.stopImmediatePropagation();}
 document.addEventListener('pointerdown',event=>{
  dismissing=false;
  if(document.querySelector('dialog:modal'))return;
  const open=panels.find(panel=>panel.open);
  if(!open||open.contains(event.target)||(open.id==='start-overlay'&&(movingDocument?$('#path'):$('#home')).contains(event.target)))return;
  dismissing=true;
  for(const panel of panels){if(panel instanceof HTMLDialogElement)panel.close();else panel.open=false;}
  consume(event);
 },{capture:true,passive:false});
 for(const type of ['pointerup','mousedown','mouseup','click','touchstart','touchend']){
  document.addEventListener(type,event=>{
   if(!dismissing||(type==='click'&&event.detail===0))return;
   consume(event);
   if(type==='click')dismissing=false;
  },{capture:true,passive:false});
 }
 document.addEventListener('pointercancel',()=>{dismissing=false;},true);
}
configurePopoverDismissal();
for(const type of ['pointerdown','mousedown']){
 $('#save').addEventListener(type,event=>{
  if(document.activeElement===$('#editor'))event.preventDefault();
 });
}
function configureLandscapeRail(){
 const root=document.documentElement,probe=document.createElement('div');
 probe.setAttribute('aria-hidden','true');
 probe.style.cssText='position:fixed;left:0;top:0;visibility:hidden;pointer-events:none;width:env(safe-area-inset-left,0px);height:env(safe-area-inset-right,0px)';
 document.body.append(probe);
 function update(){
  const bounds=probe.getBoundingClientRect(),left=bounds.width,right=bounds.height;
  const angle=((screen.orientation?.angle??window.orientation??0)+360)%360;
  const side=angle===90?'right':angle===270?'left':null;
  const inset=side==='left'?left:right;
  const fullWidth=innerWidth>=Math.max(screen.width,screen.height)-2;
  const enabled=side&&inset>=52&&fullWidth&&matchMedia('(pointer:coarse)').matches;
  if(enabled)root.dataset.rail=side;else delete root.dataset.rail;
  const height=window.visualViewport?.height??innerHeight;
  const overflow=!!enabled&&(innerHeight-height>100||height<160);
  root.toggleAttribute('data-rail-overflow',overflow);
  if(overflow)$('#document-info').open=false;
  root.style.setProperty('--visible-height',height+'px');
 }
 let scheduled=false;
 function schedule(){if(!scheduled){scheduled=true;requestAnimationFrame(()=>{scheduled=false;update();});}}
 new ResizeObserver(schedule).observe(probe);
 for(const event of ['resize','orientationchange','pageshow','load'])window.addEventListener(event,schedule);
 screen.orientation?.addEventListener('change',schedule);
 window.visualViewport?.addEventListener('resize',schedule);
 update();schedule();
}
configureLandscapeRail();
function configureEditorFocusScrolling(){
 const editor=$('#editor'),viewport=window.visualViewport;
 if(!viewport)return;
 let scheduled=false,height=viewport.height;
 function revealCaret(){
  if(scheduled||document.activeElement!==editor)return;
  scheduled=true;
  requestAnimationFrame(()=>{
   scheduled=false;
   if(document.activeElement!==editor)return;
   const mirror=document.createElement('div'),style=getComputedStyle(editor);
   for(const name of style)mirror.style.setProperty(name,style.getPropertyValue(name));
   mirror.style.cssText+=';position:absolute;left:0;top:0;visibility:hidden;pointer-events:none;height:auto;min-height:0;max-height:none;overflow:hidden;';
   mirror.style.width=editor.getBoundingClientRect().width+'px';
   mirror.setAttribute('aria-hidden','true');
   const caret=editor.selectionDirection==='backward'?editor.selectionStart:editor.selectionEnd;
   mirror.append(document.createTextNode(editor.value.slice(0,caret)));
   const tail=document.createElement('span');
   tail.textContent=editor.value.slice(caret)||'\u200b';
   mirror.append(tail);document.body.append(mirror);
   const rect=tail.getClientRects()[0];
   if(!rect){mirror.remove();return;}
   const top=editor.getBoundingClientRect().top+rect.top-mirror.getBoundingClientRect().top;
   const bottom=top+(parseFloat(style.lineHeight)||parseFloat(style.fontSize)*1.5);
   const topLimit=document.documentElement.dataset.rail?12:$('.document-toolbar').getBoundingClientRect().bottom+12;
   const bottomLimit=viewport.offsetTop+viewport.height-12;
   mirror.remove();
   if(bottom>bottomLimit)window.scrollBy({top:bottom-bottomLimit,behavior:'instant'});
   else if(top<topLimit)window.scrollBy({top:top-topLimit,behavior:'instant'});
  });
 }
 function focusWithoutScrolling(){
  if(document.activeElement!==editor&&!editor.disabled)editor.focus({preventScroll:true});
 }
 editor.addEventListener('pointerup',focusWithoutScrolling);
 editor.addEventListener('mousedown',focusWithoutScrolling);
 viewport.addEventListener('resize',()=>{
  const next=viewport.height;
  if(next<height)revealCaret();
  height=next;
 });
}
configureEditorFocusScrolling();
const wrapLinesKey='plaintext.wrapLines';
function setLineWrapping(enabled){
 $('#editor').setAttribute('wrap',enabled?'soft':'off');
 $('#wrap-lines').setAttribute('aria-pressed',String(enabled));
 if(enabled)$('#editor').scrollLeft=0;
}
let wrapLines=true;
try{wrapLines=localStorage.getItem(wrapLinesKey)!=='false';}catch{}
setLineWrapping(wrapLines);
$('#wrap-lines').onclick=()=>{
 wrapLines=!wrapLines;setLineWrapping(wrapLines);
 try{localStorage.setItem(wrapLinesKey,String(wrapLines));}catch{}
};
function targetName(target){return state.targets.find(t=>t.id===target)?.name || (target==='host'?'Host':'Unavailable container');}
async function api(operation, values={}, context=state){
 const body=EnvironmentBinary.encode(operation,{target:context.target,...values});
 activeRequests++;
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),10000);
 try{
  let response,buffer;
  try{response=await fetch('/api/environments',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Environment-Request':'1'},body,signal:controller.signal});buffer=await response.arrayBuffer();}
  catch(cause){const error=Error('Waiting for connection.');error.network=true;throw error;}
  if(!response.ok){const error=Error(new TextDecoder().decode(buffer));error.network=response.status>=500;throw error;}
  return EnvironmentBinary.decode(buffer,operation);
 }finally{activeRequests--;clearTimeout(timeout);}
}
async function discover(){
 try{const result=await api('targets');state.targets=result.targets;const select=$('#environment');select.replaceChildren(...result.targets.map(t=>{const option=new Option(t.id==='host'?`Host — ${t.name}`:t.name+(t.state==='running'?'':` · ${t.state}`),t.id);option.disabled=t.state!=='running';return option}));if(!state.targets.some(t=>t.id===state.target))select.add(new Option('Unavailable container',state.target));select.value=state.target;$('#environment-errors').textContent=result.errors.map(e=>`${e.runtime}: ${e.error}`).join(' · ');if(state.active)showPath(state.active);else $('#targetLabel').textContent=targetName(state.target);renderDocument();if(!state.active)void renderRecentFiles()}catch(e){$('#environment-errors').textContent=e.message}
}
function renderDocument(){
 $('#start-screen').hidden=!$('#start-overlay')?.open;
 for(const id of ['start-new','start-open','start-recent'])$('#'+id).disabled=state.replacing;
 for(const button of document.querySelectorAll('.recent-file,.recent-remove'))button.disabled=state.replacing;
 const doc=state.active,dirty=!!(doc?.dirty||doc?.pendingSave);
 const onHost=(doc?.target||state.target)==='host';
 $('#location-target').hidden=onHost;$('.location-separator').hidden=onHost;
 $('.document-toolbar').toggleAttribute('data-preparing-document',state.replacing&&!doc);
 if(!doc){$('#pathLabel').textContent='Untitled';$('#path').title='Move / Rename… — Untitled';}
 const saving=!!doc?.pendingSave&&doc.pendingSave.version===doc.version&&!doc.localError&&!doc.networkError&&!doc.conflict;
 $('#dirty').textContent=dirty?'Edited':'';
 $('#save').hidden=!dirty;
 $('#save').textContent=saving?'Saving…':'Save';
 $('#save').setAttribute('aria-label',saving?'Saving…':'Save');$('#save').title=saving?'Saving…':'Save';
 $('#info-name').textContent=doc?.path.split('/').pop()||'Untitled';
 $('#info-target').textContent=targetName(doc?.target||state.target);
 $('#info-path').textContent=doc?.path||'Not saved to a file';
 for(const field of ['name','target','path'])$('#overflow-info-'+field).textContent=$('#info-'+field).textContent;
 $('#document-menu summary').setAttribute('aria-label',dirty?'Document actions, edited':'Document actions');
 document.documentElement.toggleAttribute('data-edited',dirty);
 $('#review').hidden=!state.active?.conflict;
 $('#editor').disabled=!state.active||state.replacing;
 $('#save').disabled=!doc||state.replacing||saving||(!dirty&&!!doc.path);$('#move').disabled=!state.active?.path||state.replacing;
 for(const id of ['home','overflow-home','mobile-location','path','location-target'])$('#'+id).disabled=state.replacing;
 $('#download').disabled=!state.active;
 document.title=(dirty?'• ':'')+(state.active?(state.active.path.split('/').pop()||'Untitled'):'Plaintext');
}
const recentFilesKey='plaintext.recentFiles.'+storageUser;
function recentFiles(){
 try{
  const records=JSON.parse(localStorage.getItem(recentFilesKey)||'[]');
  return Array.isArray(records)?records.filter(r=>r&&typeof r.path==='string'&&r.path&&typeof r.target==='string'&&Number.isFinite(r.openedAt)):[];
 }catch{return [];}
}
function rememberFile(doc){
 if(!doc.path)return;
 const records=recentFiles().filter(r=>r.path!==doc.path||r.target!==doc.target);
 records.unshift({path:doc.path,target:doc.target,openedAt:Date.now()});
 try{localStorage.setItem(recentFilesKey,JSON.stringify(records.slice(0,30)));}catch{}
}
const removedRecentFilesKey=recentFilesKey+'.removed';
function removedRecentFiles(){
 try{const keys=JSON.parse(localStorage.getItem(removedRecentFilesKey)||'[]');return new Set(Array.isArray(keys)?keys.filter(key=>typeof key==='string'):[]);}catch{return new Set();}
}
function recentFileKey(record){return JSON.stringify([record.target,record.path]);}
function restoreRecentFile(doc){
 const removed=removedRecentFiles();
 if(removed.delete(recentFileKey(doc)))try{localStorage.setItem(removedRecentFilesKey,JSON.stringify([...removed]));}catch{}
}
function removeRecentFile(record){
 const removed=removedRecentFiles();removed.add(recentFileKey(record));
 try{
  localStorage.setItem(removedRecentFilesKey,JSON.stringify([...removed]));
  localStorage.setItem(recentFilesKey,JSON.stringify(recentFiles().filter(item=>recentFileKey(item)!==recentFileKey(record))));
  void renderRecentFiles();
 }catch{status('Could not remove this item from recent files.');}
}
async function renderRecentFiles(){
 const drafts=await localRecords(),removed=removedRecentFiles();
 const records=recentFiles().filter(record=>!removed.has(recentFileKey(record))),known=new Set(records.map(recentFileKey));
 for(const record of drafts){
  const key=JSON.stringify([record.target,record.path]);
  if(record.path&&!known.has(key)&&!removed.has(key)){records.push({path:record.path,target:record.target,openedAt:record.updatedAt||0});known.add(key);}
 }
 if(state.active&&!$('#start-overlay').open)return;
 records.sort((a,b)=>b.openedAt-a.openedAt);
 $('#recent-files').replaceChildren(...records.slice(0,30).map(record=>{
  const row=document.createElement('div'),button=document.createElement('button'),name=document.createElement('strong'),detail=document.createElement('span'),remove=document.createElement('button');
  row.className='recent-row';
  button.className='recent-file';button.disabled=state.replacing;
  name.textContent=record.path.split('/').pop();detail.textContent=targetName(record.target)+' · '+record.path;
  button.title=detail.textContent;button.append(name,detail);
  button.onclick=()=>load(record.path,{target:record.target});
  remove.className='recent-remove';remove.textContent='×';remove.title='Remove from recents';remove.setAttribute('aria-label','Remove '+name.textContent+' from recents');remove.disabled=state.replacing;
  remove.onclick=()=>removeRecentFile(record);row.append(button,remove);return row;
 }));
 $('#recent-empty').hidden=records.length>0;
}
function documentURL(doc){return '?'+new URLSearchParams({file:doc.path,target:doc.target,draft:doc.id}).toString().replace(/%2F/gi,'/');}
function showPath(doc){rememberFile(doc);$('#targetLabel').textContent=targetName(doc.target);const label=$('#pathLabel');label.replaceChildren();const parts=doc.path.split('/').filter(Boolean);const filename=document.createElement('strong');filename.textContent=parts.pop()||'Untitled';if(parts.length||doc.path.startsWith('/')){const parent=document.createElement('span');parent.className='parent-path';parent.textContent=(doc.path.startsWith('/')?'/':'')+(parts.length?parts.join('/')+'/':'');label.append(parent)}label.append(filename);$('#path').title='Move / Rename… — '+(doc.path||'Untitled');if(new URLSearchParams(location.search).get('draft')===doc.id)history.replaceState(null,'',documentURL(doc));}
let fileNotifications=null;
function updateFileNotifications(restart=false){
 const doc=state.active;
 const key=doc?.path&&doc.watching&&!doc.stopped&&!document.hidden?JSON.stringify([doc.id,doc.target,doc.user,doc.path]):null;
 if(!restart&&fileNotifications?.key===key)return;
 fileNotifications?.stream.stop();fileNotifications=null;
 if(!key)return;
 const body=EnvironmentBinary.encode('disk',{target:doc.target,path:doc.path});
 const stream=new PlaintextDrafts.Notifications({
  open:signal=>fetch('/api/watch',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Environment-Request':'1'},body,signal}),
  changed:()=>{void doc.refresh();}
 });
 fileNotifications={key,stream};void stream.connect();
}
function documentChanged(doc){
 if(state.active!==doc)return;
 const editor=$('#editor');
 if(editor.value!==doc.contents){
  const {selectionStart,selectionEnd,selectionDirection,scrollLeft}=editor;
  const x=window.scrollX,y=window.scrollY;
  editor.value=doc.contents;
  editor.setSelectionRange(Math.min(selectionStart,doc.contents.length),Math.min(selectionEnd,doc.contents.length),selectionDirection);
  editor.scrollLeft=scrollLeft;window.scrollTo(x,y);
 }
 const locationKey=JSON.stringify([doc.id,doc.path,doc.target,targetName(doc.target)]);
 if(state.locationKey!==locationKey){state.locationKey=locationKey;showPath(doc);}
 updateFileNotifications();
 renderDocument();status([doc.message,recoveryWarning].filter(Boolean).join(' · '));
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
function activate(doc){state.active?.setWatching(false);state.active=doc;doc.setWatching(!document.hidden);state.target=doc.target;$('#editor').value=doc.contents;window.scrollTo(0,0);documentChanged(doc);doc.resume();}
let navigationVersion=0,navigationTask=Promise.resolve();
function currentRoute(){
 const parameters=new URLSearchParams(location.search);
 return parameters.has('file')||parameters.has('draft')?{path:parameters.get('file')||'',target:parameters.get('target')||'host',draftID:parameters.get('draft')}:null;
}
function navigateRoute(route,mode='push'){
 if(updateFrozen)return Promise.resolve();
 const version=++navigationVersion;
 navigationTask=navigationTask.then(async()=>{
  if(version!==navigationVersion)return;
  state.replacing=true;renderDocument();
  try{
   if(state.active&&!(await state.active.persist()))throw Error(state.active.message);
   if(route?.path||route?.draftID)status('Opening…');
   const doc=route?await resolveDocument(route):null;
   if(version!==navigationVersion)return;
   history[mode==='push'?'pushState':'replaceState'](null,'',doc?documentURL(doc):location.pathname);
   $('#document-menu').open=false;$('#document-info').open=false;
   if($('#start-overlay').open)$('#start-overlay').close();
   state.locationKey=null;
   if(doc){restoreRecentFile(doc);activate(doc);}
   else{
    state.active?.setWatching(false);state.active=null;
    $('#editor').blur();$('#editor').value='';
    updateFileNotifications();renderDocument();status('');window.scrollTo(0,0);
    showStartOverlay(true);
    await renderRecentFiles();
   }
  }catch(error){
   if(version===navigationVersion){
    history.replaceState(null,'',state.active?documentURL(state.active):location.pathname);
    status(error.message);
   }
  }finally{state.replacing=false;renderDocument();}
 });
 return navigationTask;
}
function newDocument(){return navigateRoute({path:'',target:state.active?.target||state.target});}
function load(path, context={target:state.target}, draftID=null){
 if(state.active?.path===path&&state.active.target===context.target&&(!draftID||state.active.id===draftID)){if($('#start-overlay').open)$('#start-overlay').close();return;}
 return navigateRoute({path,target:context.target,draftID});
}
window.addEventListener('popstate',()=>{void navigateRoute(currentRoute(),'replace');});
async function localRecords(){
 try{return(await drafts.all()).filter(record=>record.user===storageUser).sort((a,b)=>b.updatedAt-a.updatedAt);}
 catch(e){recoveryWarning='Local recovery unavailable: '+e.message;return [];}
}
async function resolveDocument({path,target,draftID}){
 const existing=draftID&&documents.get(draftID);
 if(existing&&existing.target===target)return existing;
 const records=await localRecords();
 const local=draftID?records.find(d=>d.id===draftID&&d.target===target):path?records.find(d=>d.path===path&&d.target===target):null;
 if(local)return createDocument(local);
 if(!path)return createDocument({target,user:storageUser});
 const result=await api('state',{path},{target});
 return createDocument({target,user:storageUser,path:result.path,contents:result.contents,revision:result.revision,dirty:result.dirty,conflict:result.draftConflict,draftRevision:result.draftRevision,remoteVersion:0});
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
  const shared=await api('state',{path:doc.path},doc);
  const disk=shared.dirty?await api('disk',{path:doc.path},doc):shared;
  const dialog=document.createElement('dialog');dialog.className='conflict-dialog';
  const heading=document.createElement('h3');heading.textContent='Changes were made on another device';
  const comparison=document.createElement('div');comparison.className='comparison';
  for(const [label,text] of [['Your draft',doc.contents],...(shared.dirty?[['Shared draft',shared.contents]]:[]),['Saved file',disk.contents]]){
   const panel=document.createElement('label');panel.textContent=label;const area=document.createElement('textarea');area.readOnly=true;area.value=text;panel.append(area);comparison.append(panel);
  }
  const explanation=document.createElement('p');explanation.textContent=shared.dirty?'You can keep your draft, save a copy, or discard your draft and the shared draft to use the saved file. Discarding does not change the saved file.':'You can keep your draft, save a copy, or discard your draft to use the saved file. Discarding does not change the saved file.';
  const actions=document.createElement('div');actions.className='conflict-actions';
  for(const [title,action] of [['Keep my draft',()=>{}],[shared.dirty?'Discard drafts and use saved file':'Discard my draft and use saved file',()=>doc.discardConflict(disk.revision,shared.draftRevision)],['Save a copy…',async()=>{const path=await ask('Save a copy as',doc.path+'.copy');if(path)await doc.saveCopy(path);}],['Replace server file with my draft',()=>doc.resolveConflict(disk.revision,shared.draftRevision)]]){
   const button=document.createElement('button');button.textContent=title;button.onclick=async()=>{
    const buttons=[...actions.querySelectorAll('button')];buttons.forEach(item=>item.disabled=true);
    try{await action();dialog.close();}catch(error){explanation.textContent=error.message;buttons.forEach(item=>item.disabled=false);}
   };actions.append(button);
  }
  dialog.append(heading,explanation,comparison,actions);dialog.onclose=()=>dialog.remove();document.body.append(dialog);dialog.showModal();
 }catch(e){status('Your draft is kept on this device. Cannot compare the server file: '+e.message);}
}
$('#editor').addEventListener('compositionstart',()=>{if(state.active)state.active.composing=true;});
$('#editor').addEventListener('compositionend',()=>{if(state.active){state.active.composing=false;if(state.active.refreshNeeded)void state.active.refresh();}});
$('#editor').addEventListener('input',()=>{if(state.active&&!state.replacing)state.active.edit($('#editor').value);});
$('#editor').addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='s'){e.preventDefault();void save();}else if(e.key==='Tab'){e.preventDefault();const t=e.currentTarget;t.setRangeText('\t',t.selectionStart,t.selectionEnd,'end');t.dispatchEvent(new Event('input'));}});
$('#save').onclick=()=>save();
function positionStartOverlay(){
 const panel=$('#start-overlay');if(!panel.open)return;
 const home=movingDocument?$('#path'):$('#home'),anchor=home.getBoundingClientRect().width?home:$(movingDocument?'#document-info>summary':'#document-menu>summary');
 const rect=anchor.getBoundingClientRect(),viewport=window.visualViewport;
 const left=viewport?.offsetLeft||0,top=viewport?.offsetTop||0;
 const right=left+(viewport?.width||innerWidth),bottom=top+(viewport?.height||innerHeight);
 const side=document.documentElement.dataset.rail;
 const width=Math.min(560,right-left-16-(side?rect.width+12:0));
 let x=side==='left'?rect.right+12:side==='right'?rect.left-width-12:rect.left;
 x=Math.max(left+8,Math.min(x,right-width-8));
 const y=Math.max(top+8,side?rect.top:rect.bottom+12);
 panel.style.width=width+'px';panel.style.left=x+'px';panel.style.top=y+'px';
 panel.style.maxHeight=Math.max(44,bottom-y-8)+'px';
 panel.style.setProperty('--available-height',Math.max(44,bottom-y-10)+'px');
 panel.dataset.pointer=side||'top';
 const pointer=side?rect.top+rect.height/2-y:rect.left+rect.width/2-x;
 panel.style.setProperty('--pointer-offset',Math.max(18,Math.min(pointer,(side?Math.max(44,bottom-y-8):width)-18))+'px');
 panel.style.transformOrigin=side==='right'?'right top':'left top';
}
let startPositionScheduled=false;
function scheduleStartPosition(){
 if(startPositionScheduled)return;
 startPositionScheduled=true;requestAnimationFrame(()=>{startPositionScheduled=false;positionStartOverlay();});
}
for(const event of ['resize','orientationchange'])window.addEventListener(event,scheduleStartPosition);
window.visualViewport?.addEventListener('resize',scheduleStartPosition);
window.visualViewport?.addEventListener('scroll',scheduleStartPosition);
new ResizeObserver(scheduleStartPosition).observe($('.document-toolbar'));
function showStartOverlay(duringNavigation=false){
 const overlay=$('#start-overlay');
 if(overlay.open||(!duringNavigation&&state.replacing))return;
 movingDocument=null;overlay.dataset.mode='open';overlay.setAttribute('aria-label','Open files');$('#move-fields').hidden=true;$('#choose').textContent='Open file';$('#picker').setAttribute('aria-labelledby','start-open');
 $('#document-menu').open=false;$('#document-info').open=false;
 selectStartTab('recent');$('#start-overlay-status').textContent='';$('#start-overlay-content').insertBefore($('#start-screen'),$('#start-overlay-status'));$('#start-screen').hidden=false;
 overlay.show();$('#home').setAttribute('aria-expanded','true');positionStartOverlay();void renderRecentFiles();
}
$('#home').onclick=()=>{$('#start-overlay').open?$('#start-overlay').close():showStartOverlay();};$('#overflow-home').onclick=()=>showStartOverlay();
document.addEventListener('keydown',event=>{
 if(event.key==='Escape'&&$('#start-overlay').open&&!document.querySelector('dialog:modal')){
  event.preventDefault();$('#start-overlay').close();(movingDocument?$('#path'):$('#home')).focus({preventScroll:true});
 }
});
$('#start-overlay').addEventListener('close',()=>{
 if($('#start-overlay').open)return;
 $('#home').setAttribute('aria-expanded','false');$('#path').setAttribute('aria-expanded','false');movingDocument=null;
 state.pickerVersion++;state.target=state.active?.target||state.target;
 document.querySelector('main').prepend($('#start-screen'));renderDocument();
 if(!state.active&&!state.replacing)void newDocument();
});
$('#recover').onclick=recoverDraft;$('#download').onclick=downloadDocument;$('#review').onclick=reviewChanges;
async function moveDocument(){
 const doc=state.active;if(!doc)return;
 if($('#start-overlay').open&&movingDocument){$('#start-overlay').close();return;}
 if(!doc.path){await save(doc);return;}
 if(doc.dirty||doc.pendingSave){status('Save this file and wait for confirmation before moving it.');return;}
 showStartOverlay();movingDocument=doc;$('#start-overlay').dataset.mode='move';$('#start-overlay').setAttribute('aria-label','Move or rename file');
 $('#home').setAttribute('aria-expanded','false');$('#path').setAttribute('aria-expanded','true');
 $('#move-fields').hidden=false;$('#move-name').value=doc.path.split('/').pop();$('#choose').textContent='Move';
 $('#picker').setAttribute('aria-labelledby','move-heading');selectStartTab('open');
 state.target=doc.target;positionStartOverlay();
 void pickerLoad(doc.path.slice(0,doc.path.lastIndexOf('/'))||'/');
}
function updatePickerAction(){
 if(!movingDocument){$('#choose').disabled=!state.pickerSelected||state.pickerSelected.directory;return;}
 const name=$('#move-name').value;
 $('#choose').disabled=state.replacing||!state.pickerReady||!name.trim()||name==='.'||name==='..'||name.includes('/')||name.includes('\0');
}
async function confirmMove(){
 const doc=movingDocument;if(!doc||$('#choose').disabled)return;
 if(doc!==state.active||doc.dirty||doc.pendingSave){$('#start-overlay-status').textContent='Save this file before moving it.';return;}
 const destination=state.pickerPath.replace(/\/$/,'')+'/'+$('#move-name').value;
 if(destination===doc.path){$('#start-overlay').close();return;}
 state.replacing=true;renderDocument();updatePickerAction();$('#move-name').disabled=true;
 try{
  const result=await api('move',{path:doc.path,destination,revision:doc.revision},doc);
  doc.path=result.path;doc.draftRevision='missing';await doc.persist();documentChanged(doc);$('#start-overlay').close();
 }catch(e){$('#start-overlay-status').textContent=e.message;}
 finally{state.replacing=false;$('#move-name').disabled=false;renderDocument();updatePickerAction();}
}
$('#move-name').addEventListener('input',updatePickerAction);
$('#move-name').addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();void confirmMove();}});
$('#move').onclick=()=>{$('#document-info').open=false;void moveDocument();};$('#path').onclick=moveDocument;
const pickerSelection={entries:[],selected:null,typeaheadPrefix:'',typeaheadLastUpdated:0,parent:null};
function pickerSelectedIndex(){return pickerSelection.selected?pickerSelection.entries.findIndex(entry=>entry.path===pickerSelection.selected.path):-1;}
function selectPickerIndex(index){
 if(!pickerSelection.entries.length)return;
 index=Math.max(0,Math.min(index,pickerSelection.entries.length-1));
 const list=$('#pickerRows'),entry=pickerSelection.entries[index];
 for(const [i,row] of [...list.children].entries()){row.classList.toggle('selected',i===index);row.setAttribute('aria-selected',String(i===index));}
 const row=list.children[index];list.setAttribute('aria-activedescendant',row.id);
 state.pickerSelected=entry;pickerSelection.selected=entry;updatePickerAction();
 list.focus({preventScroll:true});row.scrollIntoView({block:'nearest'});
}
function resetTypeahead(){pickerSelection.typeaheadPrefix='';pickerSelection.typeaheadLastUpdated=0}
function selectEntryMatchingPrefix(prefix,startingAfterSelection){if(!prefix)return false;const selected=pickerSelectedIndex(),start=startingAfterSelection?(selected<0?0:selected+1):0;for(let offset=0;offset<pickerSelection.entries.length;offset++){const index=(start+offset)%pickerSelection.entries.length;if(pickerSelection.entries[index].name.toLocaleLowerCase().startsWith(prefix)){selectPickerIndex(index);return true}}return false}
function handleTypeahead(text){if(!pickerSelection.entries.length)return;const now=Date.now();if(pickerSelection.typeaheadLastUpdated&&now-pickerSelection.typeaheadLastUpdated>1000)pickerSelection.typeaheadPrefix='';pickerSelection.typeaheadLastUpdated=now;pickerSelection.typeaheadPrefix+=text.toLocaleLowerCase();if(selectEntryMatchingPrefix(pickerSelection.typeaheadPrefix,false))return;pickerSelection.typeaheadPrefix=text.toLocaleLowerCase();selectEntryMatchingPrefix(pickerSelection.typeaheadPrefix,true)}
function typeaheadText(key){return key&&![...key].some(character=>/[\u0000-\u001f\u007f-\u009f\r\n]/u.test(character))&&[...key].length===1?key:null}
document.addEventListener('keydown',event=>{
 if(!$('#start-overlay').open||$('#picker').hidden||state.replacing||event.defaultPrevented||event.isComposing||event.metaKey||event.ctrlKey||event.altKey||event.target.closest('input,textarea,select,[contenteditable="true"]'))return;
 const index=pickerSelectedIndex(),inList=event.target===$('#pickerRows');
 if(event.key==='ArrowUp'||event.key==='ArrowDown'){
  event.preventDefault();resetTypeahead();selectPickerIndex(index<0?(event.key==='ArrowUp'?pickerSelection.entries.length-1:0):index+(event.key==='ArrowUp'?-1:1));
 }else if(event.key==='Enter'&&inList&&index>=0){
  event.preventDefault();const entry=pickerSelection.entries[index];entry.directory?pickerLoad(entry.path):choose(entry.path);
 }else if(event.key==='Backspace'&&inList&&pickerSelection.parent){event.preventDefault();pickerLoad(pickerSelection.parent);}
 else{const text=typeaheadText(event.key);if(text){event.preventDefault();handleTypeahead(text);}}
});
async function pickerLoad(path){
 resetTypeahead();pickerSelection.entries=[];pickerSelection.selected=null;pickerSelection.parent=null;
 const version=++state.pickerVersion;state.pickerReady=false;state.pickerSelected=null;$('#choose').disabled=true;$('#pickerRows').replaceChildren();$('#pickerRows').removeAttribute('aria-activedescendant');$('#pickerRows').scrollTop=0;$('#pickerPath').textContent='Loading…';
 try{const value=await api('list',{path});if(version!==state.pickerVersion)return;state.pickerPath=value.path;$('#pickerPath').textContent=value.path;
 pickerSelection.parent=value.parent;
 const entries=[...(value.parent?[{name:'..',path:value.parent,directory:true}]:[]),...value.entries.filter(entry=>!movingDocument||entry.directory)];pickerSelection.entries=entries;
 $('#pickerRows').replaceChildren(...entries.map((entry,index)=>{
  const row=document.createElement('div');row.className='picker-row';row.id='picker-row-'+index;row.setAttribute('role','option');row.setAttribute('aria-selected','false');
  const icon=document.createElement('span');icon.textContent=entry.directory?'📁':'📄';icon.setAttribute('aria-hidden','true');
  const text=document.createElement('span');text.textContent=entry.name;row.append(icon,text);
  row.onclick=()=>{resetTypeahead();if(entry.directory){$('#pickerRows').focus({preventScroll:true});pickerLoad(entry.path);}else selectPickerIndex(index);};
  row.ondblclick=()=>{if(!entry.directory)choose(entry.path);};return row;
 }));
 state.pickerReady=true;updatePickerAction();
 }catch(e){if(version===state.pickerVersion){$('#pickerRows').replaceChildren();$('#pickerPath').textContent=e.message;}}
}
function selectStartTab(tab){
 resetTypeahead();
 for(const name of ['recent','open']){
  const selected=name===tab,button=$('#start-'+name);
  button.setAttribute('aria-selected',String(selected));button.tabIndex=selected?0:-1;
 }
 $('#recent-panel').hidden=tab!=='recent';$('#picker').hidden=tab!=='open';
 $('#start-overlay').dataset.tab=tab;
 scheduleStartPosition();
}
function openPicker(){
 showStartOverlay();selectStartTab('open');
 state.target=state.active?.target||state.target;$('#environment').value=state.target;
 const path=state.active?.path;pickerLoad(path&&path.includes('/')?path.slice(0,path.lastIndexOf('/'))||'/':'~');
}
function choose(path){load(path,{target:state.target});}
$('#start-recent').onclick=()=>{state.pickerVersion++;selectStartTab('recent');};
$('.start-tabs').addEventListener('keydown',event=>{
 if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
 event.preventDefault();
 const tab=event.key==='Home'?'recent':event.key==='End'?'open':$('#start-recent').getAttribute('aria-selected')==='true'?'open':'recent';
 $('#start-'+tab).click();$('#start-'+tab).focus();
});
$('#choose').onclick=e=>{e.preventDefault();if(movingDocument){void confirmMove();return;}if(state.pickerSelected&&!state.pickerSelected.directory)choose(state.pickerSelected.path);};
$('#mobile-location').onclick=openPicker;
$('#start-open').onclick=openPicker;$('#start-new').onclick=newDocument;
$('#location-target').onclick=openPicker;
$('#environment').onchange=()=>{state.target=$('#environment').value;pickerLoad('~');};
$('#environment-refresh').onclick=discover;
$('#document-menu').addEventListener('click',e=>{if(e.target.closest('button'))$('#document-menu').open=false;});
for(const id of ['document-menu','document-info']){
 const panel=$('#'+id);
 panel.addEventListener('toggle',()=>{if(panel.open)$('#'+(id==='document-menu'?'document-info':'document-menu')).open=false;});
}
window.addEventListener('beforeunload',e=>{if([...documents.values()].some(doc=>doc.localError||doc.localVersion<doc.version)){e.preventDefault();e.returnValue='';}});
window.addEventListener('storage',event=>{if((event.key===recentFilesKey||event.key===removedRecentFilesKey)&&(!state.active||$('#start-overlay').open))void renderRecentFiles();});
window.addEventListener('online',()=>{if(updateFrozen)return;updateFileNotifications(true);for(const doc of documents.values())doc.resume();void discover();});
document.addEventListener('visibilitychange',()=>{if(updateFrozen)return;for(const doc of documents.values()){doc.setWatching(doc===state.active&&!document.hidden);void doc.persist();if(!document.hidden)doc.resume();}updateFileNotifications();});
window.addEventListener('focus',()=>{if(!updateFrozen&&!document.hidden){updateFileNotifications(true);state.active?.resume();}});
window.addEventListener('pagehide',()=>{fileNotifications?.stream.stop();fileNotifications=null;for(const doc of documents.values()){void doc.persist();doc.stop();}});
window.addEventListener('pageshow',event=>{if(event.persisted){state.replacing=false;renderDocument();updateFileNotifications(true);for(const doc of documents.values())doc.resume();if(!state.active)void renderRecentFiles();}});
let shellUpdates=null,updateFrozen=false,updateEpoch=0,bootFinished=false,lastInteraction=0,activeRequests=0;
let updateView=null;
const updateViewKey='plaintext.update-view';
for(const type of ['keydown','pointerdown','beforeinput','compositionstart','compositionend','input']){
 document.addEventListener(type,event=>{
  if(updateFrozen){event.preventDefault();event.stopImmediatePropagation();return;}
  lastInteraction=Date.now();
 },true);
}
async function checkpointForUpdate(){
 if(!bootFinished||state.replacing||activeRequests||Date.now()-lastInteraction<1500||
    document.querySelector('dialog[open]:not(#start-overlay), #start-overlay:modal')||[...documents.values()].some(doc=>doc.composing))return false;
 if(!updateFrozen){
  const editor=$('#editor');
  updateView={url:location.href,id:state.active?.id,openPanel:$('#start-overlay').open,start:editor.selectionStart,end:editor.selectionEnd,
   direction:editor.selectionDirection,x:window.scrollX,y:window.scrollY,left:editor.scrollLeft,focused:document.activeElement===editor};
  updateFrozen=true;document.body.inert=true;
  fileNotifications?.stream.stop();fileNotifications=null;
  for(const doc of documents.values())doc.stop();
 }
 const epoch=updateEpoch;
 const saved=await Promise.all([...documents.values()].map(doc=>doc.persist()));
 if(epoch!==updateEpoch||!updateFrozen)return false;
 if(saved.some(value=>!value)){releaseUpdate();return false;}
 try{sessionStorage.setItem(updateViewKey,JSON.stringify(updateView));}
 catch(error){releaseUpdate();status('Could not preserve the editor for an update: '+error.message);return false;}
 return true;
}
function releaseUpdate(){
 updateEpoch++;
 if(!updateFrozen)return;
 updateFrozen=false;document.body.inert=false;
 if(updateView?.focused)$('#editor').focus({preventScroll:true});
 for(const doc of documents.values())doc.resume();
 updateFileNotifications();
}
function restoreUpdateView(){
 try{
  const value=JSON.parse(sessionStorage.getItem(updateViewKey)||'null');
  sessionStorage.removeItem(updateViewKey);
  if(!value||value.url!==location.href||value.id!==state.active?.id)return;
  const editor=$('#editor');
  editor.setSelectionRange(value.start,value.end,value.direction);
  if(value.focused)editor.focus({preventScroll:true});
  editor.scrollLeft=value.left;window.scrollTo(value.x,value.y);
  if(value.openPanel)showStartOverlay();
 }catch{}
}
async function prepareOfflineShell(){
 if(!('serviceWorker' in navigator))return;
 shellUpdates=new PlaintextDrafts.ShellUpdates({
  workers:navigator.serviceWorker,prepare:checkpointForUpdate,release:releaseUpdate,
  reload:()=>{history.replaceState(null,'',updateView.url);location.reload();},visible:()=>!document.hidden
 });
 await shellUpdates.start();
}
window.addEventListener('focus',()=>shellUpdates?.check());
window.addEventListener('online',()=>shellUpdates?.check());
window.addEventListener('pageshow',()=>shellUpdates?.check());
document.addEventListener('visibilitychange',()=>{if(!document.hidden)shellUpdates?.check();});
$('#editor').disabled=true;renderDocument();
if(!currentRoute())showStartOverlay(true);
void prepareOfflineShell();void discover();
async function boot(){
 await navigateRoute(currentRoute(),'replace');
 for(const record of await localRecords()){
  if(record.pendingSave&&!record.conflict&&!documents.has(record.id)){
   const doc=await createDocument(record,false);
   doc?.resume();
  }
 }
}
void boot().then(()=>{bootFinished=true;restoreUpdateView();shellUpdates?.check();});
})();
