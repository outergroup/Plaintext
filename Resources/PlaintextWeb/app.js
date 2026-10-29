(() => {
'use strict';
const $ = selector => document.querySelector(selector);
const query = new URLSearchParams(location.search);
const drafts = new PlaintextDrafts.Store();
const storageUser = window.outerLoop?.sessionContext?.username || '';
const documents = new Map();
let recoveryWarning = '';
const state = {target:query.get('target') || 'host', targets:[], active:null, replacing:false, pickerPath:'~', pickerSelected:null, pickerVersion:0};
function status(text){$('#status').textContent=text;$('#start-overlay-status').textContent=$('#start-overlay').open?text:'';}
function configurePopoverDismissal(){
 const panels=[$('#document-menu'),$('#document-info')];
 let dismissing=false;
 function consume(event){event.preventDefault();event.stopImmediatePropagation();}
 document.addEventListener('pointerdown',event=>{
  dismissing=false;
  const open=panels.find(panel=>panel.open);
  if(!open||open.contains(event.target))return;
  dismissing=true;
  for(const panel of panels)panel.open=false;
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
 try{const result=await api('targets');state.targets=result.targets;const select=$('#environment');select.replaceChildren(...result.targets.map(t=>{const option=new Option(t.id==='host'?`Host — ${t.name}`:t.name+(t.state==='running'?'':` · ${t.state}`),t.id);option.disabled=t.state!=='running';return option}));if(!state.targets.some(t=>t.id===state.target))select.add(new Option('Unavailable container',state.target));select.value=state.target;$('#environment-errors').textContent=result.errors.map(e=>`${e.runtime}: ${e.error}`).join(' · ');if(state.active)showPath(state.active);else $('#targetLabel').textContent=targetName(state.target);renderDocument();if(!state.active)void renderRecentFiles()}catch(e){$('#environment-errors').textContent=e.message}
}
function renderDocument(){
 document.documentElement.toggleAttribute('data-start',!state.active);
 $('#start-screen').hidden=!!state.active&&!$('#start-overlay')?.open;
 for(const id of ['start-new','start-open'])$('#'+id).disabled=state.replacing;
 for(const button of document.querySelectorAll('.recent-file'))button.disabled=state.replacing;
 const doc=state.active,dirty=!!(doc?.dirty||doc?.pendingSave);
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
async function renderRecentFiles(){
 const records=recentFiles(),known=new Set(records.map(r=>JSON.stringify([r.target,r.path])));
 for(const record of await localRecords()){
  const key=JSON.stringify([record.target,record.path]);
  if(record.path&&!known.has(key)){records.push({path:record.path,target:record.target,openedAt:record.updatedAt||0});known.add(key);}
 }
 if(state.active&&!$('#start-overlay').open)return;
 records.sort((a,b)=>b.openedAt-a.openedAt);
 $('#recent-files').replaceChildren(...records.slice(0,30).map(record=>{
  const button=document.createElement('button'),name=document.createElement('strong'),detail=document.createElement('span');
  button.className='recent-file';button.disabled=state.replacing;
  name.textContent=record.path.split('/').pop();detail.textContent=targetName(record.target)+' · '+record.path;
  button.title=detail.textContent;button.append(name,detail);
  button.onclick=()=>load(record.path,{target:record.target});return button;
 }));
 $('#recent-empty').hidden=records.length>0;
}
function documentURL(doc){return '?'+new URLSearchParams({file:doc.path,target:doc.target,draft:doc.id}).toString().replace(/%2F/gi,'/');}
function showPath(doc){rememberFile(doc);$('#targetLabel').textContent=targetName(doc.target);const label=$('#pathLabel');label.replaceChildren();const parts=doc.path.split('/').filter(Boolean);const filename=document.createElement('strong');filename.textContent=parts.pop()||'Untitled';if(parts.length){const parent=document.createElement('span');parent.className='parent-path';parent.textContent=parts.join(' / ')+' / ';label.append(parent)}label.append(filename);$('#path').title='Move / Rename… — '+(doc.path||'Untitled');if(new URLSearchParams(location.search).get('draft')===doc.id)history.replaceState(null,'',documentURL(doc));}
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
 const version=++navigationVersion;
 navigationTask=navigationTask.then(async()=>{
  if(version!==navigationVersion)return;
  state.replacing=true;renderDocument();
  try{
   if(state.active&&!(await state.active.persist()))throw Error(state.active.message);
   if(route)status('Opening…');
   const doc=route?await resolveDocument(route):null;
   if(version!==navigationVersion)return;
   history[mode==='push'?'pushState':'replaceState'](null,'',doc?documentURL(doc):location.pathname);
   $('#document-menu').open=false;$('#document-info').open=false;
   if($('#picker').open)$('#picker').close();
   if($('#start-overlay').open)$('#start-overlay').close();
   state.locationKey=null;
   if(doc)activate(doc);
   else{
    state.active?.setWatching(false);state.active=null;
    $('#editor').blur();$('#editor').value='';
    updateFileNotifications();renderDocument();status('');window.scrollTo(0,0);
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
  const actions=document.createElement('div');actions.className='conflict-actions';
  for(const [title,action] of [['Close',()=>{}],['Save a copy…',async()=>{const path=await ask('Save a copy as',doc.path+'.copy');if(path)await doc.saveCopy(path);}],['Replace server file with my draft',()=>doc.resolveConflict(disk.revision,shared.draftRevision)]]){
   const button=document.createElement('button');button.textContent=title;button.onclick=()=>{dialog.close();void action();};actions.append(button);
  }
  dialog.append(heading,comparison,actions);dialog.onclose=()=>dialog.remove();document.body.append(dialog);dialog.showModal();
 }catch(e){status('Your draft is kept on this device. Cannot compare the server file: '+e.message);}
}
$('#editor').addEventListener('compositionstart',()=>{if(state.active)state.active.composing=true;});
$('#editor').addEventListener('compositionend',()=>{if(state.active){state.active.composing=false;if(state.active.refreshNeeded)void state.active.refresh();}});
$('#editor').addEventListener('input',()=>{if(state.active&&!state.replacing)state.active.edit($('#editor').value);});
$('#editor').addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='s'){e.preventDefault();void save();}else if(e.key==='Tab'){e.preventDefault();const t=e.currentTarget;t.setRangeText('\t',t.selectionStart,t.selectionEnd,'end');t.dispatchEvent(new Event('input'));}});
$('#save').onclick=()=>save();
function showStartOverlay(){
 const overlay=$('#start-overlay');
 if(overlay.open||state.replacing)return;
 $('#document-menu').open=false;$('#document-info').open=false;
 $('#start-overlay-status').textContent='';overlay.insertBefore($('#start-screen'),$('#start-overlay-status'));$('#start-screen').hidden=false;
 overlay.showModal();void renderRecentFiles();
}
$('#home').onclick=showStartOverlay;$('#overflow-home').onclick=showStartOverlay;
$('#start-close').onclick=()=>$('#start-overlay').close();
$('#start-overlay').addEventListener('close',()=>{
 document.querySelector('main').prepend($('#start-screen'));renderDocument();
});
$('#recover').onclick=recoverDraft;$('#download').onclick=downloadDocument;$('#review').onclick=reviewChanges;
async function moveDocument(){
 const doc=state.active;if(!doc)return;
 if(!doc.path){await save(doc);return;}
 if(doc.dirty||doc.pendingSave){status('Save this file and wait for confirmation before moving it.');return;}
 const destination=await ask('Move or rename file',doc.path,'Move');if(!destination||destination===doc.path)return;
 state.replacing=true;renderDocument();
 try{const result=await api('move',{path:doc.path,destination,revision:doc.revision},doc);doc.path=result.path;doc.draftRevision='missing';await doc.persist();documentChanged(doc);}
 catch(e){status(e.message);}finally{state.replacing=false;renderDocument();}
}
$('#move').onclick=()=>{$('#document-info').open=false;void moveDocument();};$('#path').onclick=moveDocument;
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
$('#mobile-location').onclick=openPicker;
$('#start-open').onclick=openPicker;$('#start-new').onclick=newDocument;
$('#location-target').onclick=openPicker;
$('#environment').onchange=()=>{state.target=$('#environment').value;pickerLoad('~');};
$('#environment-refresh').onclick=discover;
$('#picker').addEventListener('close',()=>{state.pickerVersion++;state.target=state.active?.target||state.target;});
$('#document-menu').addEventListener('click',e=>{if(e.target.closest('button'))$('#document-menu').open=false;});
for(const id of ['document-menu','document-info']){
 const panel=$('#'+id);
 panel.addEventListener('toggle',()=>{if(panel.open)$('#'+(id==='document-menu'?'document-info':'document-menu')).open=false;});
}
window.addEventListener('beforeunload',e=>{if([...documents.values()].some(doc=>doc.localError||doc.localVersion<doc.version)){e.preventDefault();e.returnValue='';}});
window.addEventListener('storage',event=>{if(event.key===recentFilesKey&&(!state.active||$('#start-overlay').open))void renderRecentFiles();});
window.addEventListener('online',()=>{updateFileNotifications(true);for(const doc of documents.values())doc.resume();void discover();});
document.addEventListener('visibilitychange',()=>{for(const doc of documents.values()){doc.setWatching(doc===state.active&&!document.hidden);void doc.persist();if(!document.hidden)doc.resume();}updateFileNotifications();});
window.addEventListener('focus',()=>{if(!document.hidden){updateFileNotifications(true);state.active?.resume();}});
window.addEventListener('pagehide',()=>{fileNotifications?.stream.stop();fileNotifications=null;for(const doc of documents.values()){void doc.persist();doc.stop();}});
window.addEventListener('pageshow',event=>{if(event.persisted){state.replacing=false;renderDocument();updateFileNotifications(true);for(const doc of documents.values())doc.resume();if(!state.active)void renderRecentFiles();}});
async function prepareOfflineShell(){
 if(!('serviceWorker' in navigator))return;
 try{await navigator.serviceWorker.register('/sw.js',{scope:'/'});await navigator.serviceWorker.ready;}
 catch{}
}
$('#editor').disabled=true;renderDocument();
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
void boot();
})();
