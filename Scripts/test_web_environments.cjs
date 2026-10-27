const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2] + '/Resources/PlaintextWeb/app.js', 'utf8');
const save = source.slice(source.indexOf('async function save('), source.indexOf("$('#editor').addEventListener"));
(async () => {
 const doc = {path:'/test.txt',target:'docker:abc',user:'1000',contents:'first',version:1,revision:'original',dirty:true};
 const calls = []; let release;
 const context = {state:{active:doc},clearTimeout,showPath(){},renderTabs(){},status(){},api:async(operation,values,owner)=>{
  calls.push({operation,...values,target:owner.target});
  if(calls.length===1)await new Promise(resolve=>release=resolve);
  return {revision:'revision-'+calls.length};
 }};
 vm.runInNewContext(save,context);
 const first=context.save(doc); await new Promise(setImmediate);
 doc.contents='second';doc.version=2;
 const second=context.save(doc);
 await new Promise(setImmediate); assert.equal(calls.length,1);
 release();assert.equal(await first,true);assert.equal(await second,true);
 assert.deepEqual(calls.map(c=>[c.contents,c.revision,c.target]),[['first','original','docker:abc'],['second','revision-1','docker:abc']]);
 assert.equal(doc.dirty,false);assert.equal(doc.revision,'revision-2');
 const draft=context.save(doc,true);await draft;assert.equal(calls[2].operation,'draft');assert.equal(doc.revision,'revision-2');
 console.log('PASS serialized saves preserve latest contents, revision, environment, and draft state');
})().catch(error=>{console.error(error);process.exitCode=1;});
