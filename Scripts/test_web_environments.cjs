const assert=require('node:assert/strict'),path=require('node:path');
const {Document}=require(path.resolve(process.argv[2]||path.resolve(__dirname,'..'),'Resources/PlaintextWeb/offline.js'));
(async()=>{
 let release;const calls=[];
 const doc=new Document({path:'/test.txt',target:'docker:abc',contents:'first',revision:'original'},
  {store:{put:async()=>{}},schedule:()=>1,cancel(){},api:async(operation,values,owner)=>{
   calls.push({operation,...values,target:owner.target});
   if(calls.length===1)await new Promise(resolve=>release=resolve);
   return{path:'/test.txt',revision:'revision-'+calls.length};
  }});
 doc.edit('first');await doc.requestSave();await new Promise(setImmediate);
 doc.edit('second');await doc.requestSave();assert.equal(calls.length,1);
 release();await doc.sync();await doc.sync();
 assert.deepEqual(calls.map(c=>[c.contents,c.revision,c.target]),[['first','original','docker:abc'],['second','revision-1','docker:abc']]);
 assert(!doc.dirty);assert.equal(doc.revision,'revision-2');
 doc.edit('draft');await doc.sync();assert.equal(calls[2].operation,'publish');assert.equal(doc.revision,'revision-2');
 console.log('PASS serialized saves preserve latest contents, revision, environment, and draft state');
})().catch(e=>{console.error(e);process.exitCode=1;});
