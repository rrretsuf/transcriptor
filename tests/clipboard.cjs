// Validate the installed Electron clipboard API, preserving prior clipboard contents.
const {app,clipboard,ClipboardItem}=require('electron');
const assert=require('node:assert/strict');
app.whenReady().then(async()=>{
  const snapshotClipboard=async()=>Promise.all((await clipboard.read()).map(async item=>new ClipboardItem(
    Object.fromEntries(await Promise.all(item.types.map(async type=>[type,await item.getType(type)])))
  )));
  const original=await snapshotClipboard();
  const fixture='Transcriber clipboard verification';
  let written=false;
  try {
    const write=clipboard.writeText(fixture);
    assert.equal(typeof write.then,'function');await write;written=true;
    assert.equal(await clipboard.readText(),fixture);
    const current=await clipboard.read();
    console.log('Plain text clipboard types:',JSON.stringify(current.map(item=>item.types)));
    const rich=new ClipboardItem({'text/plain':new Blob([fixture],{type:'text/plain'}),'text/html':new Blob(['<b>'+fixture+'</b>'],{type:'text/html'})});
    await clipboard.write([rich]);
    const snapshot=await snapshotClipboard();
    await clipboard.writeText(fixture);
    await clipboard.write(snapshot);
    assert.ok((await clipboard.read()).some(item=>item.types.includes('text/html')));
    console.log('PASS native async write/read and full-format snapshot restore');
  } finally {
    if(written && await clipboard.readText()===fixture) await clipboard.write(original);
  }
  app.quit();
}).catch(error=>{console.error(error);app.exit(1)});
