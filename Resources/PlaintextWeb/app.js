(() => {
'use strict';
const $ = selector => document.querySelector(selector);
const query = new URLSearchParams(location.search);
const state = {target:query.get('target') || 'host', targets:[], documents:[], active:null, pickerPath:'~', pickerSelected:null, pickerVersion:0};
function status(text){$('#status').textContent=text;}
function targetName(target){return state.targets.find(t=>t.id===target)?.name || (target==='host'?'Host':'Unavailable container');}
async function api(operation, values={}, context=state){
 const response=await fetch('/api/environments',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Environment-Request':'1'},body:EnvironmentBinary.encode(operation,{target:context.target,...values})});
 if(!response.ok)throw Error(await response.text());
 return EnvironmentBinary.decode(await response.arrayBuffer(),operation);
}
async function discover(){
 try{const result=await api('targets');state.targets=result.targets;const select=$('#environment');select.replaceChildren(...result.targets.map(t=>{const option=new Option(t.id==='host'?`Host — ${t.name}`:t.name+(t.state==='running'?'':` · ${t.state}`),t.id);option.disabled=t.state!=='running';return option}));if(!state.targets.some(t=>t.id===state.target))select.add(new Option('Unavailable container',state.target));select.value=state.target;$('#environment-errors').textContent=result.errors.map(e=>`${e.runtime}: ${e.error}`).join(' · ');if(state.active)showPath(state.active);else $('#targetLabel').textContent=targetName(state.target);renderTabs()}catch(e){status(e.message)}
}
function renderTabs(){
 $('#document-tabs').replaceChildren(...state.documents.map(doc=>{const tab=document.createElement('button');tab.className=doc===state.active?'document-tab active':'document-tab';tab.setAttribute('aria-pressed',String(doc===state.active));const name=document.createElement('span');name.className='tab-name';name.textContent=`${doc.dirty?'• ':''}${doc.path.split('/').pop() || 'Untitled'}`;const place=document.createElement('span');place.className='tab-place';place.textContent=targetName(doc.target);tab.append(name,place);tab.title=targetName(doc.target)+' · '+(doc.path||'Untitled');tab.onclick=()=>activate(doc);return tab}));
 $('#dirty').textContent=state.active?.dirty?'Edited':'';
 $('#save').disabled=!state.active;$('#move').disabled=!state.active?.path;$('#close-document').disabled=!state.active;
 document.title=(state.active?.dirty?'• ':'')+(state.active?.path.split('/').pop() || 'Plaintext');
}
function showPath(doc){$('#targetLabel').textContent=targetName(doc.target);const label=$('#pathLabel');label.replaceChildren();const parts=doc.path.split('/').filter(Boolean);const filename=document.createElement('strong');filename.textContent=parts.pop()||'Untitled';if(parts.length){const parent=document.createElement('span');parent.className='parent-path';parent.textContent=parts.join(' / ')+' / ';label.append(parent)}label.append(filename);$('#path').title=doc.path||'Untitled';history.replaceState(null,'','?'+new URLSearchParams({file:doc.path,target:doc.target}));}
function activate(doc){state.active=doc;state.target=doc.target;$('#editor').value=doc.contents;$('#editor').disabled=false;showPath(doc);renderTabs();status(doc.dirty?'Unsaved draft':'Ready');}
async function load(path, context={target:state.target}){
 const existing=state.documents.find(d=>d.path===path&&d.target===context.target);if(existing){activate(existing);return;}
 status('Opening…');
 try{const result=await api('read',{path},context);const doc={...context,path:result.path,contents:result.contents,revision:result.revision,dirty:result.dirty,version:0,timer:0};state.documents.push(doc);activate(doc);if(result.draftConflict)status('Recovered draft; the file also changed on disk. Review before saving.');else if(result.dirty)status('Recovered unsaved draft');}
 catch(e){status(e.message);}
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
async function save(doc=state.active, draft=false){
 if(!doc)return false;
 if(!doc.path&&draft)return false;
 if(!doc.path){const path=await ask('Save as','~/Untitled.txt');if(!path)return false;doc.path=path;doc.revision='missing';}
 clearTimeout(doc.timer);
 const operation=(doc.saving||Promise.resolve()).then(async()=>{
  const contents=doc.contents,version=doc.version;
  try{
   const result=await api(draft?'draft':'save',{path:doc.path,contents,revision:doc.revision},doc);
   if(!draft){if(result.path)doc.path=result.path;doc.revision=result.revision;if(doc.version===version)doc.dirty=false;}
   if(state.active===doc){showPath(doc);renderTabs();status(draft?'Draft saved':doc.dirty?'Saved; newer edits remain':'Saved');}
   return true;
  }catch(e){if(state.active===doc)status(e.message);return false;}
 });
 doc.saving=operation;
 const result=await operation;
 if(doc.saving===operation)doc.saving=null;
 return result;
}
$('#editor').addEventListener('input',()=>{const doc=state.active;if(!doc)return;doc.contents=$('#editor').value;doc.version++;doc.dirty=true;renderTabs();clearTimeout(doc.timer);doc.timer=setTimeout(()=>save(doc,true),700);});
$('#editor').addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='s'){e.preventDefault();save();}else if(e.key==='Tab'){e.preventDefault();const t=e.currentTarget;t.setRangeText('\t',t.selectionStart,t.selectionEnd,'end');t.dispatchEvent(new Event('input'));}});
$('#save').onclick=()=>save();
$('#new').onclick=()=>{const doc={target:state.active?.target||state.target,path:'',contents:'',revision:'missing',dirty:false,version:0};state.documents.push(doc);activate(doc);};
$('#close-document').onclick=async()=>{const doc=state.active;if(!doc)return;if(doc.dirty){if(!doc.path){if(!(await ask('Discard this untitled document?',null,'Discard')))return;}else {const version=doc.version;if(!(await save(doc,true))||doc.version!==version)return;}}clearTimeout(doc.timer);state.documents=state.documents.filter(d=>d!==doc);state.active=null;if(state.documents.length)activate(state.documents.at(-1));else{$('#editor').value='';$('#editor').disabled=true;$('#pathLabel').textContent='Open or create a document';history.replaceState(null,'','?'+new URLSearchParams({target:state.target}));renderTabs();status('Open a file or create a new document');}};
$('#move').onclick=async()=>{const doc=state.active;if(!doc?.path)return;if(doc.dirty&&!(await save(doc)))return;const destination=await ask('Move or rename file',doc.path,'Move');if(!destination||destination===doc.path)return;try{const result=await api('move',{path:doc.path,destination,revision:doc.revision},doc);doc.path=result.path;if(state.active===doc)activate(doc);status('Moved');}catch(e){status(e.message);}};
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
window.addEventListener('beforeunload',e=>{if(state.documents.some(d=>d.dirty)){e.preventDefault();e.returnValue='';}});
$('#editor').disabled=true;renderTabs();
discover().then(()=>{const file=query.get('file');if(file)load(file);});
})();
