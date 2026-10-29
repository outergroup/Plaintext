const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../Resources/PlaintextWeb/app.js'),'utf8');
function setup(saved=null){
 const handlers={},buttons={},frames=new Map(),timers=new Map();let next=0,stored=saved,scale=1,scrolled=0;
 for(const id of ['text-smaller','text-larger','text-size-reset'])buttons[id]={addEventListener(){}};
 const editor={disabled:false,value:'unchanged draft',selectionStart:3,selectionEnd:7,
  getBoundingClientRect:()=>({top:-scrolled,height:1000*scale}),addEventListener:(name,handler)=>{handlers[name]=handler;}};
 const context=vm.createContext({Number,Math,innerHeight:800,editorPinching:false,
  $:s=>s==='#editor'?editor:s==='#start-overlay'?{open:false}:buttons[s.slice(1)],
  localStorage:{getItem:()=>stored,setItem:(_,v)=>stored=v},
  document:{activeElement:editor,documentElement:{style:{setProperty:(_,v)=>scale=Number(v)}},querySelector:()=>null,querySelectorAll:()=>Object.values(buttons)},
  window:{scrollBy:({top})=>scrolled+=top,addEventListener(){}},
  setTimeout:fn=>{timers.set(++next,fn);return next;},clearTimeout:id=>timers.delete(id),
  requestAnimationFrame:fn=>{frames.set(++next,fn);return next;},cancelAnimationFrame:id=>frames.delete(id)
 });
 vm.runInContext(source.slice(source.indexOf('function configureTextSize(){'),source.indexOf("const wrapLinesKey=")),context);
 const drain=map=>{const pending=[...map.values()];map.clear();pending.forEach(fn=>fn());};
 function event(name,values={}){let prevented=false;handlers[name]({preventDefault:()=>prevented=true,...values});drain(frames);return prevented;}
 return {buttons,editor,event,scale:()=>scale,stored:()=>stored,timers:()=>drain(timers)};
}
let ui=setup();assert.equal(ui.scale(),1);ui.buttons['text-larger'].onclick();assert.equal(ui.scale(),1.1);assert.equal(ui.stored(),'1.1');
ui=setup(ui.stored());assert.equal(ui.scale(),1.1);ui.buttons['text-size-reset'].onclick();assert.equal(ui.scale(),1);
assert(!ui.event('wheel',{ctrlKey:false,deltaY:100,deltaMode:0,clientY:200}));assert.equal(ui.scale(),1);
assert(ui.event('wheel',{ctrlKey:true,deltaY:-20,deltaMode:0,clientY:200}));assert(ui.scale()>1);ui.timers();assert.equal(Number(ui.stored()),ui.scale());
ui.buttons['text-size-reset'].onclick();ui.event('gesturestart');ui.event('gesturechange',{scale:2,clientY:200});assert.equal(ui.scale(),2);ui.event('gestureend');assert.equal(ui.stored(),'2');
ui.buttons['text-size-reset'].onclick();const touches=d=>[{clientX:0,clientY:200},{clientX:d,clientY:200}];
ui.event('touchstart',{touches:touches(100)});ui.event('gesturestart');ui.event('gesturechange',{scale:2,clientY:200});assert.equal(ui.scale(),1);
ui.event('touchmove',{touches:touches(150)});assert.equal(ui.scale(),1.5);ui.event('touchend',{touches:[]});assert.equal(ui.stored(),'1.5');
ui.event('gesturestart');ui.event('gesturechange',{scale:100,clientY:200});assert.equal(ui.scale(),3);assert(ui.buttons['text-larger'].disabled);
ui.event('gesturechange',{scale:.001,clientY:200});assert.equal(ui.scale(),.25);assert(ui.buttons['text-smaller'].disabled);ui.event('gestureend');
assert.equal(ui.editor.value,'unchanged draft');assert.equal(ui.editor.selectionStart,3);assert.equal(ui.editor.selectionEnd,7);
assert.equal(setup('NaN').scale(),1);
console.log('PASS menu sizing, reset, persistence, trackpad wheel, Safari gestures, touch pinch, duplicate-event suppression, bounds, and preserved text/selection');
