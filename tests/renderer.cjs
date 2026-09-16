// Runs only fixture data in isolated Electron windows; no microphone, API or user settings.
const { app, BrowserWindow, nativeTheme } = require('electron');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'transcriber-quality-'));
app.setPath('userData', path.join(temp, 'profile'));
const preload = path.join(temp, 'preload.cjs');
fs.writeFileSync(preload, `
window.calls = []; window.handlers = {};
window.fixture = [{id:'one', text:'A test transcription. '.repeat(80), at:Date.now(), words:240, durationMs:60000}];
window.app = new Proxy({}, {get:(_, key) => {
  if (key.startsWith('on')) return fn => window.handlers[key] = fn;
  return async (...args) => {
    window.calls.push([key, ...args]);
    if(key==='getConfig') return {apiKey:'', model:'stt-rt-v5', languageHints:['en'], hotkey:'Command+Shift+Space', position:'bottom', silenceStopMs:0};
    if(key==='historyList') return window.fixture;
    if(key==='localStats') return {count:1, words:240};
    if(key==='usage') return {ok:true,costUsd:0,requests:0,audioMs:0,dailyCost:[]};
    if(key==='usageOpenrouter') return {ok:true,keyUsage:0.01,keyLimit:null,local:{count:2,promptTokens:100,completionTokens:50,costUsd:0.0002}};
    if(key==='permStatus') return {microphone:'granted',accessibility:true};
  };
}});
`);
app.whenReady().then(async () => {
  const win = new BrowserWindow({show:false,width:580,height:720,backgroundColor:'#202020',webPreferences:{preload,contextIsolation:false,offscreen:true,backgroundThrottling:false}});
  const run = code => win.webContents.executeJavaScript(code);
  const load = file => win.loadFile(path.join(__dirname, '../renderer', file));
  try {
    await load('settings.html');
    const settings = await run(`(async()=>{
      await new Promise(r=>setTimeout(r,40));
      const h=document.querySelector('header').getBoundingClientRect().top;
      const m=document.querySelector('main'); m.scrollTop=10000;
      save({autoPaste:false}); save({restoreClipboard:true});
      return {headerTop:document.querySelector('header').getBoundingClientRect().top,
        initialTop:h,titleTop:document.querySelector('h1').getBoundingClientRect().top,
        scrolled:m.scrollTop, calls:window.calls.filter(c=>c[0]==='setConfig')};
    })()`);
    assert.equal(settings.headerTop, settings.initialTop);
    assert.ok(settings.titleTop >= 50);
    assert.ok(settings.scrolled > 0);
    assert.equal(settings.calls.length, 2);
    await run(`document.querySelector('main').scrollTop=0`);
    await new Promise(r=>setTimeout(r,700));
    fs.writeFileSync(path.join(temp,'settings.png'),(await win.webContents.capturePage()).toPNG());
    await load('history.html');
    const history = await run(`(async()=>{
      await new Promise(r=>setTimeout(r,30));
      document.querySelector('.entry').click(); render();
      const preserved=document.querySelector('.entry').getAttribute('aria-expanded');
      search.value='<img src=x onerror=alert(1)>';render();
      return {preserved, injected:!!list.querySelector('img'),literal:list.textContent.includes('<img')};
    })()`);
    assert.equal(history.preserved, 'true'); assert.equal(history.injected,false); assert.equal(history.literal,true);
    await run(`search.value='';render()`);
    fs.writeFileSync(path.join(temp,'history.png'),(await win.webContents.capturePage()).toPNG());
    await load('pill.html');
    for (const position of ['bottom','left','right']) {
      win.setContentSize(position==='bottom'?440:474, position==='bottom'?214:180);
      const result = await run(`(()=>{
        window.handlers.onLayout({position:${JSON.stringify(position)},open:true,height:180});
        finalText='Short text.';renderTranscript();
        const short=window.calls.filter(c=>c[0]==='contentHeight').at(-1)[1];
        finalText='A longer transcription with many words. '.repeat(150);renderTranscript();
        const long=window.calls.filter(c=>c[0]==='contentHeight').at(-1)[1];
        scrollEl.scrollTop=0;scrollEl.dispatchEvent(new Event('scroll'));
        finalText+=' New words.';renderTranscript();
        const rect=id=>{const r=document.getElementById(id).getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}};
        return {short,long,scrollTop:scrollEl.scrollTop,control:rect('control'),panel:rect('panel'),text:rect('text')};
      })()`);
      assert.equal(result.short,96); assert.ok(result.long>180); assert.equal(result.scrollTop,0);
      assert.equal(result.panel.width,440);
      if(position==='left') assert.equal(result.control.x,0);
      if(position==='right') assert.equal(result.control.x,440);
      if(position==='bottom') assert.equal(result.control.y,180);
      console.log('PASS renderer',position,JSON.stringify(result));
      await new Promise(r=>setTimeout(r,200));
      fs.writeFileSync(path.join(temp,position+'.png'),(await win.webContents.capturePage()).toPNG());
    }
    await load('settings.html');
    await run(`new Promise(r=>setTimeout(r,30))`);
    const saveFailure = await run(`(async()=>{
      const original=window.app.setConfig;
      window.app=new Proxy(window.app,{get:(target,key)=>key==='setConfig'?async()=>{throw Error('Disk full')}:target[key]});
      const old=config.autoPaste;
      const saved=await save({autoPaste:!old});
      await Promise.all([save({context:"first failed"}),save({context:"second failed"})]);
      if (config.context !== savedConfig.context) throw Error("Failed saves did not restore persisted value");
      return {saved,restored:config.autoPaste===old,visible:!document.getElementById('saveStatus').hidden};
    })()`);
    assert.equal(saveFailure.saved,false);assert.equal(saveFailure.restored,true);assert.equal(saveFailure.visible,true);
    for (const theme of ['light','dark']) {
      nativeTheme.themeSource=theme;
      win.setBackgroundColor(theme==='light'?'#f5f5f7':'#202020');
      win.setContentSize(500,520);
      await load('settings.html');
      await new Promise(r=>setTimeout(r,700));
      const overflow=await run(`(()=>{
        const m=document.querySelector('main');
        return [...m.querySelectorAll('input,select,textarea,button')].filter(el=>el.getBoundingClientRect().right>innerWidth).map(el=>el.id);
      })()`);
      assert.equal(overflow.length,0);
      fs.writeFileSync(path.join(temp,'settings-'+theme+'.png'),(await win.webContents.capturePage()).toPNG());
    }
    await load('pill.html');
    const cancelled = await run(`(async()=>{
      let resolveInput; let stopped=false;
      Object.defineProperty(navigator.mediaDevices,'getUserMedia',{value:()=>new Promise(r=>resolveInput=r)});
      window.WebSocket=class {static OPEN=1; constructor(){this.readyState=0} close(){this.readyState=3}};
      const pending=start({languageHints:[]});cancel();
      resolveInput({getTracks:()=>[{stop(){stopped=true}}]});await pending;
      return stopped && stream===null && worklet===null && source===null;
    })()`);
    assert.equal(cancelled,true);
    console.log('PASS settings padding + independent saves; history filtering + expansion; cancel during microphone startup');
    fs.writeFileSync(path.join(temp,'pill.png'),(await win.webContents.capturePage()).toPNG());
    console.log('Artifacts:',temp);
    win.destroy();app.quit();
  } catch(error) { console.error(error);app.exit(1); }
});
