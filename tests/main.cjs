const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');

function harness(t) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'transcriber-store-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const events={},handlers={},timers=[],registered=new Set(['Command+Shift+Space']),steps=[];
  let clipboardText='original',clipboardItems=[{types:['text/html','text/plain'],getType:async()=> 'original'}];
  let failRename=false,failDecrypt=false,encryptions=0,decryptions=0,pasteError=null,accessible=true;
  let fetchImpl=async()=>{throw Error('no fetch mock')};
  const notes=[];
  const fakeFS={...fs,renameSync:(a,b)=>{if(failRename)throw Error('Disk full');fs.renameSync(a,b)}};
  const electron={
    app:{getPath:()=>dir,requestSingleInstanceLock:()=>true,whenReady:()=>({then(){}}),on(){},focus(){},getLoginItemSettings:()=>({openAtLogin:false})},
    systemPreferences:{isTrustedAccessibilityClient:()=>accessible,getMediaAccessStatus:()=>'granted'},
    BrowserWindow:class {loadFile(){return Promise.resolve()} once(){} on(){} show(){} focus(){} isFocused(){return false} isDestroyed(){return false} webContents={send(){},on(){}}},
    shell:{openExternal(){}},
    ipcMain:{on:(key,fn)=>events[key]=fn,handle:(key,fn)=>handlers[key]=fn},
    safeStorage:{isEncryptionAvailable:()=>true,encryptString:text=>{encryptions++;return Buffer.from(text)},decryptString:b=>{decryptions++;if(failDecrypt)throw Error('locked');return b.toString()}},
    globalShortcut:{register:key=>{if(key==='taken')return false;registered.add(key);return true},unregister:key=>registered.delete(key),unregisterAll:()=>registered.clear()},
    clipboard:{read:async()=>clipboardItems,readText:async()=>clipboardText,
      writeText:async text=>{steps.push('write');await Promise.resolve();clipboardText=text;clipboardItems=[{types:['text/plain']}]},
      write:async items=>{steps.push('restore');clipboardItems=items;clipboardText='original'}},
    ClipboardItem:class {constructor(data){this.types=Object.keys(data)}},
    nativeImage:{createFromPath:()=>({setTemplateImage(){}})},Menu:{buildFromTemplate:items=>items},
    Notification:class {constructor(note){notes.push(note)} static isSupported(){return true} show(){}},
    screen:{getCursorScreenPoint:()=>({}),getDisplayNearestPoint:()=>({workArea:{x:0,y:0,width:1440,height:900}})},
  };
  const context=vm.createContext({require:name=>name==='electron'?electron:name==='node:fs'?fakeFS:name==='node:child_process'?{
    execFile:(_file,_args,callback)=>{steps.push('paste');callback(pasteError)},
    spawn:()=>({stdout:{on(){}},on(){},kill(){}})
  }:require(name),process,Buffer,fetch:(...a)=>fetchImpl(...a),AbortSignal,AbortController,
  __dirname:path.resolve(__dirname,'..'),setTimeout:fn=>{timers.push(fn);return timers.length},clearTimeout(){},setImmediate(fn){fn()}});
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../main.js'),'utf8')+`
    tray={setContextMenu(){},setImage(){}};
    surface={hide(){},setBounds(){},getBounds:()=>({x:0,y:0,width:132,height:34}),showInactive(){},webContents:{send(){}}};
    globalThis.api={loadConfig,loadHistory,saveConfig,writeJSON,pasteAtCursor,recordTranscript,readTap,unlockApiKey,
      cleanupWanted,cleanupTranscript,CLEANUP_PROMPTS,CLEANUP_TIERS,
      emailWanted,emailTranscript,emailRequest,EMAIL_SYSTEM_PROMPT,registerHotkeys:()=>registerHotkey(),
      config:()=>config,history:()=>history,last:()=>lastTranscript,
      setState:(s)=>{state=s},setSession:(id)=>{sessionId=id},setMode:(m)=>{sessionMode=m},
      patch:p=>config={...config,...p}};
  `,context);
  return {dir,api:context.api,handlers,events,registered,timers,steps,notes,
    setFailRename:v=>failRename=v,setFailDecrypt:v=>failDecrypt=v,setPasteError:v=>pasteError=v,
    setAccessible:v=>accessible=v,setFetch:v=>fetchImpl=v,
    runTimers:()=>{for(const fn of timers.splice(0)) fn()},
    encryptions:()=>encryptions,decryptions:()=>decryptions,setClipboard:text=>clipboardText=text,clipboardItems:()=>clipboardItems,clipboardText:()=>clipboardText};
}
test('failed atomic replacement leaves original bytes intact',t=>{
  const h=harness(t),file=path.join(h.dir,'config.json');fs.writeFileSync(file,'{"old":true}');h.setFailRename(true);
  assert.throws(()=>h.api.writeJSON(file,{new:true}),/Disk full/);assert.equal(fs.readFileSync(file,'utf8'),'{"old":true}');
});
test('unavailable hotkey keeps existing hotkey and saved settings',t=>{
  const h=harness(t);assert.throws(()=>h.handlers['config:set']({}, {hotkey:'taken'}),/previous hotkey/);
  assert.equal(h.api.config().hotkey,'Command+Shift+Space');assert.ok(h.registered.has('Command+Shift+Space'));
});
test('failed setting save rolls back new shortcut registration',t=>{
  const h=harness(t);h.setFailRename(true);assert.throws(()=>h.handlers['config:set']({}, {hotkey:'Command+Shift+K'}));
  assert.ok(h.registered.has('Command+Shift+Space'));assert.equal(h.registered.has('Command+Shift+K'),false);
});
test('encrypted key is reused for unrelated saves and retained when keychain is locked',t=>{
  const h=harness(t),file=path.join(h.dir,'config.json');
  const encrypted=Buffer.from('fixture-key').toString('base64');fs.writeFileSync(file,JSON.stringify({apiKeyEnc:encrypted,position:'left'}));
  h.setFailDecrypt(true);h.api.loadConfig();h.handlers['config:set']({}, {autoPaste:false});
  assert.equal(JSON.parse(fs.readFileSync(file)).apiKeyEnc,encrypted);assert.equal(h.api.config().position,'left');assert.equal(h.encryptions(),0);
});
test('invalid store is kept intact and cannot be overwritten',t=>{
  const h=harness(t),file=path.join(h.dir,'config.json');fs.writeFileSync(file,'broken');h.api.loadConfig();
  assert.throws(()=>h.api.saveConfig(),/not been overwritten/);assert.equal(fs.readFileSync(file,'utf8'),'broken');
});
test('history disabled still keeps latest transcription in memory',t=>{
  const h=harness(t);h.api.patch({saveHistory:false});h.api.recordTranscript('last text',1000);
  assert.equal(h.api.last(),'last text');assert.equal(h.api.history().length,0);
});
test('failed history delete retains in-memory and disk history',t=>{
  const h=harness(t);h.api.recordTranscript('keep',1000);const id=h.api.history()[0].id;h.setFailRename(true);
  assert.throws(()=>h.handlers['history:delete']({},id));assert.equal(h.api.history().length,1);
  assert.equal(JSON.parse(fs.readFileSync(path.join(h.dir,'history.json'))).length,1);
});
test('paste waits for async write and restores rich clipboard formats',async t=>{
  const h=harness(t);h.api.patch({restoreClipboard:true});await h.api.pasteAtCursor('transcript');
  assert.deepEqual(h.steps,['write','paste']);await h.timers[0]();assert.ok(h.clipboardItems()[0].types.includes('text/html'));
});
test('newer copy prevents clipboard restore',async t=>{
  const h=harness(t);h.api.patch({restoreClipboard:true});await h.api.pasteAtCursor('transcript');h.setClipboard('new copy');
  await h.timers[0]();assert.equal(h.clipboardText(),'new copy');assert.equal(h.steps.includes('restore'),false);
});
test('failed paste leaves transcription available instead of restoring old clipboard',async t=>{
  const h=harness(t);h.api.patch({restoreClipboard:true});h.setPasteError(Error('denied'));await h.api.pasteAtCursor('transcript');
  assert.equal(h.clipboardText(),'transcript');assert.equal(h.timers.length,0);
});

test('paste without Accessibility keeps the transcription and says so instead of failing silently',async t=>{
  const h=harness(t);h.setAccessible(false);
  await h.api.pasteAtCursor('Hello there');
  assert.equal(h.clipboardText(),'Hello there');
  assert.ok(!h.steps.includes('paste'));
  assert.match(h.notes.at(-1).title,/cannot paste/i);
  await h.api.pasteAtCursor('Again');
  assert.equal(h.notes.filter(note=>/cannot paste/i.test(note.title)).length,1);
});

test('a modifier tapped twice starts dictation; one tap alone does not',async t=>{
  const h=harness(t);h.api.patch({apiKey:'key',hotkey:'tap:Command:2'});
  const flags=v=>h.api.readTap('flags '+v);
  flags(0x100000);flags(0);
  await new Promise(r=>setTimeout(r,0));
  assert.ok(!h.registered.has('Escape'));
  flags(0x100000);flags(0);
  await new Promise(r=>setTimeout(r,0));
  assert.ok(h.registered.has('Escape'));
});
test('a modifier used in a real shortcut never counts as a trigger tap',async t=>{
  const h=harness(t);h.api.patch({apiKey:'key',hotkey:'tap:Command:2'});
  for (let i=0;i<3;i++) {
    h.api.readTap('flags 1048576');h.api.readTap('key');h.api.readTap('flags 0');
  }
  h.api.readTap('flags 1179648');h.api.readTap('flags 0');
  h.api.readTap('flags 1179648');h.api.readTap('flags 0');
  await new Promise(r=>setTimeout(r,0));
  assert.ok(!h.registered.has('Escape'));
});

test('a tap hotkey is watched natively instead of being registered as a shortcut',t=>{
  const h=harness(t);
  h.handlers['config:set']({}, {hotkey:'tap:Fn:2'});
  assert.equal(h.api.config().hotkey,'tap:Fn:2');
  assert.equal(h.registered.has('tap:Fn:2'),false);
  assert.equal(h.registered.has('Command+Shift+Space'),false);
  h.handlers['config:set']({}, {hotkey:'Control+Alt+D'});
  assert.ok(h.registered.has('Control+Alt+D'));
});
test('settings written by an older version drop keys this version no longer has',t=>{
  const h=harness(t),file=path.join(h.dir,'config.json');
  fs.writeFileSync(file,JSON.stringify({hotkey:'Control+K',trigger:'DoubleCommand'}));
  h.api.loadConfig();
  assert.equal(h.api.config().hotkey,'Control+K');
  assert.equal('trigger' in h.api.config(),false);
});

test('cleanup tier accepts light/medium/hard and rejects anything else',t=>{
  const h=harness(t);
  h.handlers['config:set']({}, {cleanupEnabled:true, cleanupTier:'hard'});
  assert.equal(h.api.config().cleanupTier,'hard');
  assert.throws(()=>h.handlers['config:set']({}, {cleanupTier:'ultra'}),/Invalid cleanup tier/);
  assert.equal(h.api.config().cleanupTier,'hard');
});
test('cleanup is wanted only when enabled, keyed and the text is real',t=>{
  const h=harness(t);
  const text='eee pač to je res pravi testni stavek';
  assert.equal(h.api.cleanupWanted(text),false);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light'});
  assert.equal(h.api.cleanupWanted(text),false);
  h.api.patch({openrouterKey:'sk-or-test'});
  assert.equal(h.api.cleanupWanted(text),true);
  assert.equal(h.api.cleanupWanted('hi there'),false);
  assert.equal(h.api.cleanupWanted('   '),false);
});
test('cleanup posts to OpenRouter with baseten routing and reasoning disabled',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'medium', openrouterKey:'sk-or-test'});
  let seen;
  h.setFetch(async (url, opts)=>{
    seen={url,opts,body:JSON.parse(opts.body)};
    return {status:200, ok:true, json:async()=>({choices:[{message:{content:'  Cleaned text.  '}}]})};
  });
  const result=await h.api.cleanupTranscript('eee pač to je res pravi testni stavek a veš', new AbortController().signal);
  assert.equal(result.ok,true);
  assert.equal(result.text,'Cleaned text.');
  assert.equal(seen.url,'https://openrouter.ai/api/v1/chat/completions');
  assert.equal(seen.body.model,'thinkingmachines/inkling-small');
  assert.deepEqual(seen.body.provider,{order:['baseten'],allow_fallbacks:true});
  assert.equal(seen.body.stream,false);
  assert.equal(seen.body.reasoning?.effort,'none');
  assert.equal(seen.body.reasoning?.exclude,true);
  assert.ok(seen.body.max_completion_tokens>=1200&&seen.body.max_completion_tokens<=4000);
  assert.equal('max_tokens' in seen.body,false);
  assert.equal('temperature' in seen.body,false);
  assert.equal(seen.opts.headers.Authorization,'Bearer sk-or-test');
  assert.equal(seen.body.messages.length,2);
});
test('cleanup failure never throws and falls back to the original',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test'});
  h.setFetch(async()=>({status:500, ok:false}));
  const failed=await h.api.cleanupTranscript('eee pač to je res pravi testni stavek', new AbortController().signal);
  assert.equal(failed.ok,false);
  assert.equal(failed.reason,'HTTP 500');
  h.setFetch(async()=>({status:200, ok:true, json:async()=>({choices:[{message:{content:'   '}}]})}));
  const empty=await h.api.cleanupTranscript('eee pač to je res pravi testni stavek', new AbortController().signal);
  assert.equal(empty.ok,false);
  assert.equal(empty.reason,'empty/blank');
});
test('cleanup retries once after a 429 then succeeds',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test'});
  let calls=0;
  h.setFetch(async()=>{
    calls++;
    if(calls===1) return {status:429, ok:false};
    return {status:200, ok:true, json:async()=>({choices:[{message:{content:'Recovered.'}}]})};
  });
  const pending=h.api.cleanupTranscript('eee pač to je res pravi testni stavek a veš', new AbortController().signal);
  for (let i=0;i<20 && h.timers.length===0;i++) await new Promise(r=>setImmediate(r));
  h.runTimers();
  const result=await pending;
  assert.equal(result.ok,true);
  assert.equal(result.text,'Recovered.');
  assert.equal(calls,2);
});
test('session result polishes the transcript before pasting when cleanup is on',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test'});
  h.setFetch(async()=>({status:200, ok:true, json:async()=>({choices:[{message:{content:'Polished text here.'}}]})}));
  h.api.setSession(9);
  h.api.setState('finishing');
  await h.events['session:result']({},{id:9, text:'eee pač raw text tukaj res', durationMs:1000});
  assert.equal(h.clipboardText(),'Polished text here.');
  assert.equal(h.api.last(),'Polished text here.');
});
test('session result pastes the original when cleanup fails',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'hard', openrouterKey:'sk-or-test'});
  h.setFetch(async()=>({status:500, ok:false}));
  h.api.setSession(11);
  h.api.setState('finishing');
  await h.events['session:result']({},{id:11, text:'eee pač raw text tukaj res', durationMs:1000});
  assert.equal(h.clipboardText(),'eee pač raw text tukaj res');
  assert.equal(h.api.last(),'eee pač raw text tukaj res');
});
test('cleanup uses the configured model and provider, or auto routing when empty',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test',
    cleanupModel:'x/custom-model', cleanupProvider:'deepinfra/fp8'});
  let seen;
  h.setFetch(async (url, opts)=>{
    seen=JSON.parse(opts.body);
    return {status:200, ok:true, json:async()=>({choices:[{message:{content:'Done.'}}]})};
  });
  const custom=await h.api.cleanupTranscript('eee pač to je res pravi testni stavek', new AbortController().signal);
  assert.equal(custom.ok,true);
  assert.equal(seen.model,'x/custom-model');
  assert.equal(seen.provider.order[0],'deepinfra');
  assert.equal(seen.provider.allow_fallbacks,true);
  assert.equal(seen.provider.quantizations[0],'fp8');
  h.api.patch({cleanupProvider:''});
  await h.api.cleanupTranscript('eee pač to je res pravi testni stavek', new AbortController().signal);
  assert.equal('provider' in seen,false);
});
test('cleanup system prompt carries languages and vocabulary from settings',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test',
    languageHints:['sl','en'], context:'ENKI, Transcriber\nSoniox'});
  let seen;
  h.setFetch(async (url, opts)=>{
    seen=JSON.parse(opts.body);
    return {status:200, ok:true, json:async()=>({choices:[{message:{content:'Done.'}}]})};
  });
  await h.api.cleanupTranscript('eee pač to je res pravi testni stavek', new AbortController().signal);
  const system=seen.messages[0].content;
  assert.ok(system.includes('Slovenian'));
  assert.ok(system.includes('English'));
  assert.ok(system.includes('ENKI'));
  assert.ok(system.includes('Transcriber'));
  assert.ok(system.includes('Soniox'));
  h.api.patch({languageHints:[], context:''});
  await h.api.cleanupTranscript('eee pač to je res pravi testni stavek', new AbortController().signal);
  assert.equal(seen.messages[0].content.includes('transcript is in'),false);
  assert.equal(seen.messages[0].content.includes('domain terms'),false);
});
test('cleanup falls back from no reasoning to low reasoning when the model rejects it',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test'});
  const bodies=[];
  let calls=0;
  h.setFetch(async (url, opts)=>{
    bodies.push(JSON.parse(opts.body));
    calls++;
    if(calls===1) return {status:400, ok:false};
    return {status:200, ok:true, json:async()=>({choices:[{message:{content:'Recovered.'}}]})};
  });
  const result=await h.api.cleanupTranscript('eee pač to je res pravi testni stavek', new AbortController().signal);
  assert.equal(result.ok,true);
  assert.equal(result.text,'Recovered.');
  assert.equal(calls,2);
  assert.equal(bodies[0].reasoning.effort,'none');
  assert.equal(bodies[1].reasoning.effort,'low');
  assert.ok(bodies[1].max_completion_tokens>bodies[0].max_completion_tokens);
});
test('cleanup finally uses provider-default reasoning when explicit efforts are rejected',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test'});
  const bodies=[];
  let calls=0;
  h.setFetch(async (url, opts)=>{
    bodies.push(JSON.parse(opts.body));
    calls++;
    if(calls<3) return {status:400, ok:false};
    return {status:200, ok:true, json:async()=>({choices:[{message:{content:'Recovered.'}}]})};
  });
  const result=await h.api.cleanupTranscript('eee pač to je res pravi testni stavek', new AbortController().signal);
  assert.equal(result.ok,true);
  assert.equal(calls,3);
  assert.equal(bodies[0].reasoning.effort,'none');
  assert.equal(bodies[1].reasoning.effort,'low');
  assert.equal('reasoning' in bodies[2],false);
});
test('cleanup retries a length-limited empty reasoning response with more output room',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test'});
  const bodies=[];
  h.setFetch(async (url, opts)=>{
    bodies.push(JSON.parse(opts.body));
    if(bodies.length===1) return {status:200,ok:true,json:async()=>({choices:[{finish_reason:'length',message:{content:'',reasoning:'thinking'}}],
      usage:{completion_tokens:1200,completion_tokens_details:{reasoning_tokens:1200}}})};
    return {status:200,ok:true,json:async()=>({choices:[{finish_reason:'stop',message:{content:'Recovered.'}}]})};
  });
  const result=await h.api.cleanupTranscript('eee pač to je res pravi testni stavek',new AbortController().signal);
  assert.equal(result.ok,true);
  assert.equal(result.text,'Recovered.');
  assert.equal(bodies.length,2);
  assert.ok(bodies[1].max_completion_tokens>bodies[0].max_completion_tokens);
});
test('cleanup accepts normalized text content arrays',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test'});
  h.setFetch(async()=>({status:200,ok:true,json:async()=>({choices:[{message:{content:[{type:'text',text:'Cleaned '},{type:'text',text:'text.'}]}}]})}));
  const result=await h.api.cleanupTranscript('eee pač to je res pravi testni stavek',new AbortController().signal);
  assert.equal(result.text,'Cleaned text.');
});
test('verify model reports existence, verify provider checks the endpoint',async t=>{
  const h=harness(t);
  h.setFetch(async (url)=>{
    if(String(url).endsWith('/endpoints')) return {status:200, ok:true, json:async()=>({data:{endpoints:[
      {provider_name:'BaseTen', quantization:'fp8'}, {provider_name:'DeepInfra', quantization:'fp8'}]}})};
    return {status:200, ok:true, json:async()=>({data:[
      {id:'thinkingmachines/inkling-small', name:'Inkling Small', context_length:1048576},
      {id:'thinkingmachines/inkling-large', name:'Inkling Large', context_length:1048576}]})};
  });
  const model=await h.handlers['openrouter:verify-model']({},{key:'k', model:'thinkingmachines/inkling-small'});
  assert.equal(model.ok,true);
  assert.equal(model.name,'Inkling Small');
  const provider=await h.handlers['openrouter:verify-provider']({},{key:'k', model:'thinkingmachines/inkling-small', provider:'baseten/fp8'});
  assert.equal(provider.ok,true);
  assert.equal(provider.provider,'BaseTen');
  const missing=await h.handlers['openrouter:verify-provider']({},{key:'k', model:'thinkingmachines/inkling-small', provider:'nope'});
  assert.equal(missing.ok,false);
  assert.ok(missing.available.includes('BaseTen'));
  const auto=await h.handlers['openrouter:verify-provider']({},{key:'k', model:'thinkingmachines/inkling-small', provider:''});
  assert.equal(auto.ok,true);
  assert.equal(auto.auto,true);
  const gone=await h.handlers['openrouter:verify-model']({},{key:'k', model:'thinkingmachines/no-such-model'});
  assert.equal(gone.ok,false);
  assert.ok(gone.available.includes('thinkingmachines/inkling-small'));
});
test('verify provider uses the raw author/slug path',async t=>{
  const h=harness(t);
  let seenUrl='';
  h.setFetch(async (url)=>{
    seenUrl=String(url);
    return {status:200, ok:true, json:async()=>({data:{endpoints:[{provider_name:'OpenAI', quantization:'unknown'}]}})};
  });
  const provider=await h.handlers['openrouter:verify-provider']({},{key:'k', model:'openai/gpt-5.6-luna', provider:'openai'});
  assert.equal(provider.ok,true);
  assert.equal(provider.provider,'OpenAI');
  assert.ok(seenUrl.includes('/models/openai/gpt-5.6-luna/endpoints'));
  assert.equal(seenUrl.includes('%2F'),false);
});
test('email uses its own model and the email prompt, not the cleanup prompt',async t=>{
  const h=harness(t);
  h.api.patch({emailEnabled:true, openrouterKey:'sk-or-test',
    emailModel:'x/email-model', emailProvider:'', cleanupModel:'x/cleanup-model'});
  let seen;
  h.setFetch(async (url, opts)=>{
    seen=JSON.parse(opts.body);
    return {status:200, ok:true, json:async()=>({choices:[{message:{content:'Zadeva: Test\n\nživjo, test. lp, filip'}}]})};
  });
  const result=await h.api.emailTranscript('eee pač napiši jim da zamujam a veš res');
  assert.equal(result.ok,true);
  assert.equal(seen.model,'x/email-model');
  assert.equal('provider' in seen,false);
  assert.ok(seen.messages[0].content.includes('zadeva:'));
  assert.ok(seen.messages[0].content.includes('LOWERCASE ALWAYS'));
  assert.ok(seen.messages[0].content.includes('lep pozdrav'));
  assert.equal(h.api.emailWanted('eee pač napiši jim da zamujam a veš res'),true);
  h.api.patch({emailEnabled:false});
  assert.equal(h.api.emailWanted('eee pač napiši jim da zamujam a veš res'),false);
});
test('email prompt demands all-lowercase with lep pozdrav plus filip closing',t=>{
  const h=harness(t);
  const prompt=h.api.EMAIL_SYSTEM_PROMPT;
  assert.ok(prompt.includes('ENTIRE output is lowercase'));
  assert.ok(prompt.includes('zadeva: <short subject>'));
  assert.ok(prompt.includes('lep pozdrav,'));
  assert.equal(prompt.includes('LP,'),false);
  assert.equal(prompt.includes('Lep pozdrav, Filip'),false);
  assert.equal(prompt.includes('Zadeva:'),false);
});
test('email output is lowercase while URLs retain their original form',async t=>{
  const h=harness(t);
  h.api.patch({emailEnabled:true,openrouterKey:'sk-or-test',context:'Check Your Website'});
  let system='';
  h.setFetch(async(_url,opts)=>{system=JSON.parse(opts.body).messages[0].content;return {status:200,ok:true,json:async()=>({choices:[{message:{content:'Zadeva: TEST\n\nŽivjo, poglej https://Example.COM/Path\n\nLep pozdrav,\nFilip'}}]})}});
  const result=await h.api.emailTranscript('prosim napiši testni email in dodaj link');
  assert.equal(result.text,'zadeva: test\n\nživjo, poglej https://Example.COM/Path\n\nlep pozdrav,\nfilip');
  assert.ok(system.includes('follow the lowercase rule above'));
  assert.equal(system.includes('Preserve these domain terms exactly as written'),false);
});
test('email hotkey registers alongside the dictate hotkey',t=>{
  const h=harness(t);
  h.api.patch({emailEnabled:true});
  h.api.registerHotkeys();
  assert.ok(h.registered.has('Command+Shift+E'));
  assert.ok(h.registered.has('Command+Shift+Space'));
  h.api.patch({emailEnabled:false});
  h.registered.clear();
  h.api.registerHotkeys();
  assert.equal(h.registered.has('Command+Shift+E'),false);
});
test('session result in email mode pastes the structured email',async t=>{
  const h=harness(t);
  h.api.patch({emailEnabled:true, openrouterKey:'sk-or-test'});
  h.setFetch(async()=>({status:200, ok:true, json:async()=>({choices:[{message:{content:'zadeva: zamuda\n\nživjo, zamujam.\n\nlep pozdrav,\nfilip'}}],
    usage:{prompt_tokens:50, completion_tokens:20, total_tokens:70, cost:0.0002}})}));
  h.api.setSession(31);
  h.api.setState('finishing');
  h.api.setMode('email');
  await h.events['session:result']({},{id:31, text:'eee pač napiši jim da zamujam res močno', durationMs:1000});
  assert.ok(h.clipboardText().startsWith('zadeva:'));
  assert.ok(h.api.last().startsWith('zadeva:'));
  const stats=JSON.parse(fs.readFileSync(path.join(h.dir,'cleanup-stats.json'),'utf8'));
  assert.equal(stats.emailCount,1);
});
test('session result in email mode pastes raw text when email is off',async t=>{
  const h=harness(t);
  h.api.patch({emailEnabled:false, openrouterKey:'sk-or-test'});
  let calls=0;
  h.setFetch(async()=>{calls++; return {status:200, ok:true, json:async()=>({choices:[{message:{content:'X'}}]})};});
  h.api.setSession(33);
  h.api.setState('finishing');
  h.api.setMode('email');
  await h.events['session:result']({},{id:33, text:'eee pač raw text tukaj res', durationMs:1000});
  assert.equal(h.clipboardText(),'eee pač raw text tukaj res');
  assert.equal(calls,0);
});
test('successful cleanup accumulates local cost stats on disk',async t=>{
  const h=harness(t);
  h.api.patch({cleanupEnabled:true, cleanupTier:'light', openrouterKey:'sk-or-test'});
  h.setFetch(async()=>({status:200, ok:true, json:async()=>({choices:[{message:{content:'Polished.'}}],
    usage:{prompt_tokens:40, completion_tokens:20, total_tokens:60, cost:0.0001}})}));
  h.api.setSession(21);
  h.api.setState('finishing');
  await h.events['session:result']({},{id:21, text:'eee pač raw text tukaj res', durationMs:1000});
  const stats=JSON.parse(fs.readFileSync(path.join(h.dir,'cleanup-stats.json'),'utf8'));
  assert.equal(stats.count,1);
  assert.equal(stats.promptTokens,40);
  assert.equal(stats.completionTokens,20);
  assert.ok(Math.abs(stats.costUsd-0.0001)<1e-12);
});
test('openrouter usage reports key spend plus local cleanup stats',async t=>{
  const h=harness(t);
  h.api.patch({openrouterKey:'sk-or-test'});
  h.setFetch(async()=>({status:200, ok:true, json:async()=>({data:{usage:1.25, limit:10}})}));
  const usage=await h.handlers['openrouter:usage']({});
  assert.equal(usage.ok,true);
  assert.equal(usage.keyUsage,1.25);
  assert.equal(usage.keyLimit,10);
  assert.equal(usage.local.count,0);
  h.api.patch({openrouterKey:''});
  const missing=await h.handlers['openrouter:usage']({});
  assert.equal(missing.ok,false);
  assert.equal(missing.local.count,0);
});
test('openrouter key is encrypted separately from the soniox key',t=>{
  const h=harness(t),file=path.join(h.dir,'config.json');
  h.handlers['config:set']({},{apiKey:'snx_secret',openrouterKey:'sk-or-secret'});
  const saved=JSON.parse(fs.readFileSync(file));
  assert.ok(saved.apiKeyEnc);
  assert.ok(saved.openrouterKeyEnc);
  assert.equal(saved.apiKeyEnc===saved.openrouterKeyEnc,false);
  assert.equal('apiKey' in saved,false);
  assert.equal('openrouterKey' in saved,false);
});
test('startup never waits on the keychain; the key is unlocked only when it is needed',t=>{
  const h=harness(t);
  fs.writeFileSync(path.join(h.dir,'config.json'),JSON.stringify({apiKeyEnc:Buffer.from('snx_secret').toString('base64')}));
  h.api.loadConfig();
  assert.equal(h.decryptions(),0);
  assert.equal(h.api.config().apiKey,'');
  h.api.unlockApiKey();
  assert.equal(h.decryptions(),1);
  assert.equal(h.api.config().apiKey,'snx_secret');
  h.api.unlockApiKey();
  assert.equal(h.decryptions(),1);
});
test('a keychain that refuses to unlock keeps the stored key instead of wiping it',t=>{
  const h=harness(t),file=path.join(h.dir,'config.json');
  const stored=Buffer.from('snx_secret').toString('base64');
  fs.writeFileSync(file,JSON.stringify({apiKeyEnc:stored}));
  h.api.loadConfig();h.setFailDecrypt(true);h.api.unlockApiKey();
  assert.equal(h.api.config().apiKey,'');
  h.api.saveConfig();
  assert.equal(JSON.parse(fs.readFileSync(file,'utf8')).apiKeyEnc,stored);
});
