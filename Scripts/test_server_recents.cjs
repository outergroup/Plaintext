const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),vm=require('node:vm');
const {spawn,spawnSync}=require('node:child_process');
const root=path.join(__dirname,'..');
const codec=vm.runInThisContext(fs.readFileSync(path.join(root,'Resources/PlaintextWeb/environment.js'),'utf8')+';EnvironmentBinary');
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'plaintext-recents-'));
const env={...process.env,XDG_STATE_HOME:path.join(directory,'state')};
const driver=process.argv[2];
function decode(bytes,operation){return JSON.parse(codec.decode(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length),operation).contents);}
function call(operation='recents',values={},environment=env){
 const result=spawnSync(driver,[],{input:codec.encode(operation,values),env:environment});
 assert.equal(result.status,0,result.stderr.toString());
 return decode(result.stdout,operation);
}
function concurrentRemember(index){return new Promise((resolve,reject)=>{
 const process=spawn(driver,[],{env});const output=[];process.stdout.on('data',chunk=>output.push(chunk));process.on('error',reject);
 process.on('close',code=>{try{assert.equal(code,0);decode(Buffer.concat(output),'rememberRecent');resolve();}catch(error){reject(error);}});
 process.stdin.end(codec.encode('rememberRecent',{path:'/concurrent/'+index}));
});}
(async()=>{
 assert.deepEqual(call(),[]);
 const file={path:'/quoted " café\n\\.txt',target:'host'};
 assert.deepEqual(call('rememberRecent',file),[file]);
 assert.deepEqual(call(),[file],'Recents must survive a new backend process');
 const container={...file,target:'docker:example'};
 assert.deepEqual(call('rememberRecent',container),[container,file]);
 assert.deepEqual(call('rememberRecent',file),[file,container]);
 assert.deepEqual(call('removeRecent',file),[container]);
 assert.deepEqual(call('removeRecent',file),[container]);
 assert.deepEqual(call('removeRecent',container),[]);
 await Promise.all(Array.from({length:20},(_,index)=>concurrentRemember(index)));
 assert.equal(call().length,20,'Concurrent updates must not overwrite one another');
 for(let i=20;i<40;i++)call('rememberRecent',{path:'/concurrent/'+i});
 const limited=call();assert.equal(limited.length,30);assert.equal(limited[0].path,'/concurrent/39');
 assert.equal(new Set(limited.map(record=>record.path)).size,30);
 assert.deepEqual(call('recents',{}, {...env,XDG_STATE_HOME:path.join(directory,'other-user')}),[]);
 assert.throws(()=>call('rememberRecent',{path:'relative.txt'}),/absolute path/);
 const source=fs.readFileSync(path.join(root,'Resources/PlaintextWeb/app.js'),'utf8');
 const functions=source.slice(source.indexOf('let recentFilesTask='),source.indexOf('async function renderRecentFiles()'));
 function client(){const context=vm.createContext({api:async(operation,values,context)=>({contents:JSON.stringify(call(operation,{...values,target:context.target}))}),renderRecentFiles:async()=>{},status:message=>{throw Error(message);},localStorage:{getItem(){throw Error('Recents must not read browser storage');},setItem(){throw Error('Recents must not write browser storage');}}});vm.runInContext(functions,context);return context;}
 const first=client(),second=client();
 first.rememberFile(file);await first.updateRecentFiles();
 assert.equal((await second.updateRecentFiles())[0].path,file.path);
 await second.removeRecentFile(file);
 first.rememberFile(file);await first.updateRecentFiles();
 assert(!(await first.updateRecentFiles()).some(record=>record.path===file.path),'A redraw must not resurrect a removed recent');
 first.rememberFile({path:file.path,target:file.target});await first.updateRecentFiles();
 assert.equal((await second.updateRecentFiles())[0].path,file.path,'Opening a file again must restore it');
 const storage=path.join(env.XDG_STATE_HOME,'outershell/plaintext-environments');
 const filename=path.join(storage,fs.readdirSync(storage).find(name=>name.endsWith('.recents')));
 fs.writeFileSync(filename,'corrupt');
 assert.throws(()=>call(),/Invalid recent files storage/);
 assert.throws(()=>call('rememberRecent',file),/Invalid recent files storage/);
 assert.equal(fs.readFileSync(filename,'utf8'),'corrupt');
 console.log('PASS server recents: persistence, concurrency, target/user isolation, ordering, cap, removal, shared web clients, and corruption handling');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>fs.rmSync(directory,{recursive:true,force:true}));
