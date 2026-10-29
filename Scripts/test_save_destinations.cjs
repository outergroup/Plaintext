const assert=require('node:assert/strict');
const {Document}=require('../Resources/PlaintextWeb/offline.js');
(async()=>{
 const files=new Map(),records=[];
 const api=async(op,value,doc)=>{
  const key=doc.target+':'+value.path;
  if(op==='commit'){assert.equal(value.revision,'missing');files.set(key,value.contents);return{path:value.path,contents:value.contents,revision:'saved',draftRevision:'missing'};}
  return{path:value.path,contents:files.get(key)||'',revision:'saved',draftRevision:'missing'};
 };
 const doc=new Document({path:'',target:'host',contents:'draft',dirty:true},{api,store:{put:async r=>records.push(r)},schedule:()=>1,cancel:()=>{}});
 assert(await doc.saveTo('/tmp/note.txt','container-a'));
 await doc.sync();assert.equal(files.get('container-a:/tmp/note.txt'),'draft');assert(!files.has('host:/tmp/note.txt'));
 assert(await doc.saveTo('/tmp/note.txt','host',true));await doc.sync();
 assert.equal(files.get('host:/tmp/note.txt'),'draft');assert.equal(files.get('container-a:/tmp/note.txt'),'draft');
 assert.equal(records.at(-1).target,'host');assert.equal(records.at(-1).path,'/tmp/note.txt');
 await assert.rejects(doc.saveTo('/tmp/note.txt','host',true),/different name/);doc.stop();
 console.log('PASS new-file destination, cross-target copy with identical paths, persistent target, same-file copy guard');
})().catch(e=>{console.error(e);process.exitCode=1});
