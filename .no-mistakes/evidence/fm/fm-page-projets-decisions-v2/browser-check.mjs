import {spawn} from 'node:child_process';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath,pathToFileURL} from 'node:url';
const evidence=path.dirname(fileURLToPath(import.meta.url));
const profile=path.join(process.cwd(),'.test-tmp/manual/chrome-profile');
await mkdir(profile,{recursive:true});
const chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--remote-debugging-port=0','--user-data-dir='+profile],{stdio:'ignore'});
const pause=ms=>new Promise(r=>setTimeout(r,ms));
let ws;const pending=new Map();let id=0;
async function send(method,params={}){const n=++id;return new Promise((resolve,reject)=>{pending.set(n,{resolve,reject});ws.send(JSON.stringify({id:n,method,params}));});}
async function evaluate(expression){const r=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});assert(!r.exceptionDetails,JSON.stringify(r.exceptionDetails));return r.result.value;}
async function shot(name){const {contentSize}=await send('Page.getLayoutMetrics');const r=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true,clip:{x:0,y:0,width:contentSize.width,height:contentSize.height,scale:1}});await writeFile(path.join(evidence,name),Buffer.from(r.data,'base64'));}
try{
 let port;
 for(let n=0;n<100;n++){try{port=(await readFile(path.join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0];break;}catch{await pause(100);}}
 assert(port,'Chrome did not expose CDP');
 const target=await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`,{method:'PUT'})).json();
 ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true});});
 ws.addEventListener('message',e=>{const r=JSON.parse(e.data);if(r.id){const p=pending.get(r.id);pending.delete(r.id);r.error?p.reject(Error(JSON.stringify(r.error))):p.resolve(r.result);}});
 await send('Page.enable');
 const results=[];
 for(const page of ['projets','a-valider']){
  await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false});
  await send('Page.navigate',{url:pathToFileURL(path.join(evidence,page+'.html')).href});
  for(let n=0;n<100;n++){if(await evaluate('!!document.querySelector("[data-choice]")'))break;await pause(50);}
  const before=await evaluate(`(()=>{const rail=document.querySelector('button[data-project="club"]');if(rail)rail.click();return {title:document.title,rows:[...document.querySelectorAll('.you li')].map(e=>({key:e.dataset.decision,page:e.querySelector('.page').innerText,url:e.querySelector('[data-page]')?.href||null}))}})()`);
  assert.equal(before.rows.find(r=>r.key==='club-rose').url,'http://localhost:4387/session/final');
  assert.equal(before.rows.find(r=>r.key==='club-sans-page').url,null);
  assert.match(before.rows.find(r=>r.key==='club-sans-page').page,/pas de page dédiée/);
  await shot(page+'-desktop.png');
  await evaluate(`window.testQueue=[];window.testSendCalls=0;window.lavish={queuePrompt:(prompt,context)=>{window.testQueue.push({prompt,tag:context.tag,queueKey:context.queueKey,data:context.data});return true;},sendQueuedPrompts:()=>{window.testSendCalls++;}}`);
  const queued=await evaluate(`(()=>{document.querySelector('[data-decision="club-rose"] [data-choice="on-y-va"]').click();document.querySelector('[data-decision="club-audit"] [data-choice="pas-maintenant"]').click();for(const key of ['club-rose','club-audit'])document.querySelector('[data-select="'+key+'"]').click();document.querySelector('[data-create-lavish="club"]').click();return {queue:window.testQueue,sendCalls:window.testSendCalls,pendingRows:document.querySelectorAll('.you li').length,messages:[...document.querySelectorAll('.queued .ok,.group.queued .src')].map(e=>e.innerText)}})()`);
  assert.equal(queued.sendCalls,0);assert.equal(queued.queue.length,3);assert.equal(queued.pendingRows,4);
  assert.deepEqual(queued.queue.map(r=>r.tag),['choice','choice','create-lavish']);
  assert.deepEqual(queued.queue[2].data.decisions,['club-rose','club-audit']);
  assert(queued.queue.every(r=>!('answer' in r.data)&&!('question' in r.data)));
  await shot(page+'-queued.png');
  await send('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
  await pause(150);
  assert(await evaluate('document.documentElement.scrollWidth<=390'),'phone overflows');
  await shot(page+'-phone.png');
  results.push({page,viewportChecks:[1440,390],before,...queued});
 }
 await writeFile(path.join(evidence,'browser-results.json'),JSON.stringify({setup:'Real generated pages in Chrome; Lavish queue API instrumented in-memory. No live session or message sent.',results},null,2));
 console.log(JSON.stringify(results.map(r=>({page:r.page,queued:r.queue.map(q=>q.tag),sendCalls:r.sendCalls,unresolved:r.pendingRows})),null,2));
 await send('Browser.close');
}finally{if(ws)ws.close();chrome.kill();}
