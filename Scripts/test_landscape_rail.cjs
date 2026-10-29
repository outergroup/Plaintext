const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/../Resources/PlaintextWeb/app.js','utf8');
const configure=source.slice(source.indexOf('function configureLandscapeRail()'),source.indexOf('function configureEditorFocusScrolling()'));
for(const angle of [90,270]){
 const events={},frames=[],attributes=new Set(),root={dataset:{},style:{setProperty(){}},toggleAttribute(name,value){value?attributes.add(name):attributes.delete(name)}};
 let safe=0,height=370,observer;
 const probe={style:{},setAttribute(){},getBoundingClientRect:()=>({width:safe,height:safe})};
 const info={open:false};
 const viewport={get height(){return height},addEventListener:(event,fn)=>events['viewport-'+event]=fn};
 const context={document:{documentElement:root,body:{append(){}},createElement:()=>probe},$:()=>info,
  innerWidth:874,innerHeight:370,screen:{width:402,height:874,orientation:{angle,addEventListener(){}}},
  window:{visualViewport:viewport,addEventListener:(event,fn)=>events[event]=fn},matchMedia:()=>({matches:true}),
  ResizeObserver:class{constructor(callback){observer=callback}observe(target){assert.equal(target,probe)}},
  requestAnimationFrame:fn=>frames.push(fn)};
 vm.runInNewContext(configure,context);
 function flush(){while(frames.length)frames.shift()()}
 flush();assert.equal(root.dataset.rail,undefined);
 safe=62;observer();flush();assert.equal(root.dataset.rail,angle===90?'right':'left');
 assert(!attributes.has('data-rail-overflow'));
 info.open=true;height=94;events['viewport-resize']();flush();
 assert(attributes.has('data-rail-overflow'));assert(!info.open);
 height=370;events['viewport-resize']();flush();assert(!attributes.has('data-rail-overflow'));
 safe=0;observer();flush();assert.equal(root.dataset.rail,undefined);
 safe=62;events.pageshow();flush();assert(root.dataset.rail);
}
console.log('PASS late initial safe-area availability, both landscape orientations, keyboard overflow, collapse and page restoration');
