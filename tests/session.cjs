const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function harness() {
  let time = 1000, timerId = 0;
  const timers = new Map(), calls = [], sockets = [], tracks = [];
  const nodes = new Map();
  const element = id => {
    if (!nodes.has(id)) nodes.set(id, {dataset:{},textContent:'',title:'',scrollTop:0,scrollHeight:20,clientHeight:50,
      style:{setProperty(){},getPropertyValue(){return 0}},addEventListener(){},getBoundingClientRect:()=>({height:20})});
    return nodes.get(id);
  };
  class Socket {
    static CONNECTING = 0; static OPEN = 1;
    constructor() {this.readyState=0;this.bufferedAmount=0;this.sent=[];sockets.push(this)}
    send(data) {this.sent.push(data)}
    open() {this.readyState=1;this.onopen?.()}
    close() {this.readyState=3;this.onclose?.()}
    message(data) {this.onmessage?.({data:JSON.stringify(data)})}
  }
  class Audio {
    audioWorklet={addModule:async()=>{}};
    createMediaStreamSource(){return {connect(){},disconnect(){}}}
    async resume(){} async suspend(){} async close(){}
  }
  class Worklet {
    port={onmessage:null,postMessage:()=>this.port.onmessage?.({data:{flushed:true}}),close(){}};
    disconnect(){}
  }
  const app = new Proxy({}, {get:(_,key)=> (...args)=>calls.push([key,...args])});
  const context = vm.createContext({document:{getElementById:element,querySelectorAll:()=>[element('bar')]},
    window:{app},getComputedStyle:()=>({paddingTop:'2',paddingBottom:'12'}),
    WebSocket:Socket, AudioContext:Audio,AudioWorkletNode:Worklet,
    navigator:{mediaDevices:{getUserMedia:async()=>{const track={stopped:false,stop(){this.stopped=true}};tracks.push(track);return {getTracks:()=>[track]}}}},
    performance:{now:()=>time},requestAnimationFrame:fn=>fn(),
    setTimeout:(fn,delay)=>{const id=++timerId;timers.set(id,{fn,at:time+delay});return id},clearTimeout:id=>timers.delete(id)});
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../renderer/pill.js'),'utf8')+`
    globalThis.api={start,stop,cancel,onAudioChunk, snapshot:()=>({socket,stream,worklet,queue,stopping,silenceStart})};
  `,context);
  return {api:context.api,calls,sockets,tracks,timers,advance:ms=>{
    time+=ms;
    for(const [id,timer] of [...timers]) if(timer.at<=time){timers.delete(id);timer.fn()}
  }};
}
const cfg={id:7,model:'test',languageHints:[]};

test('stop before connection opens keeps queued audio and sends terminator after audio',async()=>{
  const h=harness();await h.api.start(cfg);
  h.api.onAudioChunk({pcm:new ArrayBuffer(1280),rms:.1});
  await h.api.stop();h.sockets[0].open();
  assert.equal(h.sockets[0].sent.length,3);
  assert.equal(h.sockets[0].sent.at(-1),'');
  assert.ok(h.tracks.every(t=>t.stopped));h.api.cancel();
  assert.equal(h.api.snapshot().socket,null);
});
test('disconnect recovers recognized text and releases microphone',async()=>{
  const h=harness();await h.api.start(cfg);const ws=h.sockets[0];ws.open();
  ws.message({tokens:[{text:'Keep this',is_final:true},{text:' partial',is_final:false}]});ws.close();
  const error=h.calls.find(c=>c[0]==='error')[1];assert.equal(error.text,'Keep this partial');assert.equal(error.id,7);
  assert.ok(h.tracks.every(t=>t.stopped));assert.equal(h.api.snapshot().socket,null);
});
test('connection timeout closes resources instead of recording indefinitely',async()=>{
  const h=harness();await h.api.start(cfg);h.advance(10001);
  assert.match(h.calls.find(c=>c[0]==='error')[1].message,/timed out/);assert.equal(h.api.snapshot().socket,null);
});
test('finalization duration excludes server wait and finishes only once',async()=>{
  const h=harness();await h.api.start(cfg);const ws=h.sockets[0];ws.open();h.advance(1000);
  ws.message({tokens:[{text:'hello',is_final:true}]});await h.api.stop();h.advance(2000);ws.message({finished:true});h.advance(10000);
  const results=h.calls.filter(c=>c[0]==='result');assert.equal(results.length,1);assert.equal(results[0][1].durationMs,1000);
  assert.equal(h.api.snapshot().socket,null);
});
test('silence must be continuous, not accumulated across quieter speech',async()=>{
  const h=harness();await h.api.start({...cfg,silenceStopMs:1500});h.sockets[0].open();
  const chunk=rms=>h.api.onAudioChunk({pcm:new ArrayBuffer(1280),rms});chunk(.1);chunk(0);h.advance(1000);chunk(.015);h.advance(700);chunk(0);
  assert.equal(h.calls.filter(c=>c[0]==='autostop').length,0);h.advance(1600);chunk(0);
  assert.equal(h.calls.filter(c=>c[0]==='autostop').length,1);h.api.cancel();
});
test('slow socket buffer fails with bounded memory',async()=>{
  const h=harness();await h.api.start(cfg);h.sockets[0].open();h.sockets[0].bufferedAmount=500000;
  h.api.onAudioChunk({pcm:new ArrayBuffer(1280),rms:.1});assert.match(h.calls.find(c=>c[0]==='error')[1].message,/too slow/);
});
test('cancel followed by a new session cannot receive old socket results',async()=>{
  const h=harness();await h.api.start(cfg);const old=h.sockets[0];h.api.cancel();await h.api.start({...cfg,id:8});
  old.message({tokens:[{text:'stale',is_final:true}],finished:true});assert.equal(h.calls.filter(c=>c[0]==='result').length,0);
  h.api.cancel();assert.equal(h.api.snapshot().socket,null);
});
test('worklet flush preserves the last incomplete audio chunk',()=>{
  let Processor;
  class Base {port={messages:[],postMessage(data){this.messages.push(data)}}}
  const context=vm.createContext({AudioWorkletProcessor:Base,registerProcessor:(_name,p)=>Processor=p});
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../renderer/pcm-processor.js'),'utf8'),context);
  const processor=new Processor();processor.process([[new Float32Array(128).fill(.5)]]);
  processor.port.onmessage({data:'flush'});
  assert.equal(processor.port.messages[0].pcm.byteLength,256);assert.equal(processor.port.messages[1].flushed,true);
});

test('vocabulary is sent as structured terms and translation keeps only translated output',async()=>{
  const h=harness();await h.api.start({...cfg,context:'Soniox, Filip Kustec\nENKI',translateTo:'en'});const ws=h.sockets[0];ws.open();
  assert.deepEqual(JSON.parse(ws.sent[0]).context,{terms:['Soniox','Filip Kustec','ENKI']});
  ws.message({tokens:[{text:'izvirnik',is_final:true,translation_status:'original'},
    {text:'translated',is_final:true,translation_status:'translation'},
    {text:'<end>',is_final:true,translation_status:'translation'}],finished:true});
  assert.equal(h.calls.find(c=>c[0]==='result')[1].text,'translated');
});
