const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../Resources/PlaintextWeb/app.js'),'utf8');
const handlers={};
class Dialog{constructor(){this.open=true;}contains(){return false;}close(){this.open=false;}}
const panel=new Dialog();
const context=vm.createContext({HTMLDialogElement:Dialog,innerWidth:390,movingDocument:null,
 $:selector=>selector==='#start-overlay'?panel:selector==='#home'?{contains:()=>false}:null,
 document:{querySelector:()=>null,addEventListener:(type,handler)=>{handlers[type]=handler;}}});
vm.runInContext(source.slice(source.indexOf('function configurePopoverDismissal(){'),source.indexOf("for(const type of ['pointerdown','mousedown'])")),context);
function send(type,values={}){let consumed=false;handlers[type]({target:{},pointerType:'touch',clientX:150,detail:1,preventDefault(){consumed=true;},stopImmediatePropagation(){},...values});return consumed;}
for(const clientX of [0,16,32,358,380,390]){
 panel.open=true;assert(!send('pointerdown',{clientX}));assert(panel.open);
 assert(!send('touchstart'));assert(!send('pointerup'));assert(!send('touchend'));
 send('pointercancel');
}
panel.open=true;assert(send('pointerdown'));assert(!panel.open);assert(send('touchstart'));assert(send('pointerup'));assert(send('click'));
panel.open=true;assert(send('pointerdown',{pointerType:'mouse',clientX:10}));assert(!panel.open);
send('pointercancel');assert(!send('touchend'));
console.log('PASS touch edge gestures stay unconsumed, ordinary outside taps dismiss without click-through, and mouse dismissal still works');
