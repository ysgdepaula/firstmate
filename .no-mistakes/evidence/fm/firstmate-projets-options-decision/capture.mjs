import {spawn} from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
const root=process.cwd();
const evidence='/Users/ydeep/.no-mistakes/evidence/01M2A5ST0DQBH4GMNAAM438FQS';
const profile=path.join(root,'.test-phase-tmp/evidence-chrome');
await fs.mkdir(profile,{recursive:true});
const browser=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-features=GoogleUpdater','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],{stdio:'ignore'});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let ws;
try {
 let port;
 for(let i=0;i<150;i++){try{port=(await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0];break;}catch{await sleep(200);}}
 assert(port,'Chrome debugging endpoint did not start');
 const pages=await(await fetch(`http://127.0.0.1:${port}/json/list`)).json();
 ws=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
 await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject;});
 let seq=0;const pending=new Map();
 ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){const [resolve,reject]=pending.get(m.id);pending.delete(m.id);m.error?reject(new Error(JSON.stringify(m.error))):resolve(m.result);}};
 const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++seq;pending.set(id,[resolve,reject]);ws.send(JSON.stringify({id,method,params}));});
 const evaluate=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});assert(!r.exceptionDetails,JSON.stringify(r.exceptionDetails));return r.result.value;};
 await call('Page.enable');
 await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false});
 await call('Page.navigate',{url:'file://'+evidence+'/projets.html'});
 for(let i=0;i<100;i++){if(await evaluate('document.querySelectorAll("[data-choice]").length === 9'))break;await sleep(100);}
 assert.equal(await evaluate('document.querySelectorAll("[data-choice]").length'),9);
 const visible=await evaluate(`Array.from(document.querySelectorAll('[data-decision]')).map(r=>({key:r.dataset.decision,nature:r.dataset.nature,text:r.innerText,buttons:Array.from(r.querySelectorAll('button')).map(b=>b.textContent)}))`);
 assert(visible[1].text.includes('je ne sais pas si c’est déjà fait'));
 assert.deepEqual(visible[0].buttons,['on y va','on ne le fait pas','pas maintenant','on en parle']);
 async function screenshot(name){const r=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});await fs.writeFile(path.join(evidence,name),Buffer.from(r.data,'base64'));}
 await screenshot('projets-desktop.png');
 await call('Emulation.setDeviceMetricsOverride',{width:390,height:1150,deviceScaleFactor:1,mobile:true});
 await call('Page.reload');await sleep(700);
 assert.equal(await evaluate('window.innerWidth'),390);
 assert.equal(await evaluate('document.documentElement.scrollWidth'),390);
 await screenshot('projets-phone.png');
 // The real renderer is unchanged; a test adapter observes its outbound Lavish calls.
 await evaluate(`window.__sent=[]; window.lavish={queuePrompt(text,context){window.__sent.push({text,data:context.data});},sendQueuedPrompts(){return true;}};`);
 for(const [key,choice] of [['torre-relance','on-ne-le-fait-pas'],['torre-domaine','pas-encore']]){
  await evaluate(`document.querySelector('[data-decision="${key}"] [data-choice="${choice}"]').click()`);
 }
 const sent=await evaluate('window.__sent');
 assert.deepEqual(sent.map(x=>x.data),[{projet:'torre',decision:'torre-relance',choix:'on-ne-le-fait-pas',nature:'decision'},{projet:'torre',decision:'torre-domaine',choix:'pas-encore',nature:'etat'}]);
 assert(sent.every(x=>!('question' in x.data)&&!('answer' in x.data)));
 assert.equal(await evaluate('document.querySelectorAll("[data-decision]").length'),3);
 const statuses=await evaluate('Array.from(document.querySelectorAll(".you .ok")).map(e=>e.textContent)');
 await screenshot('projets-clicks.png');
 await fs.writeFile(path.join(evidence,'browser-clicks.json'),JSON.stringify({adapter:'Local test adapter captures real renderer queuePrompt/sendQueuedPrompts calls; no live supervisor messages sent.',visible,sent,statuses,cardsRemain:3,phoneWidth:390,phoneScrollWidth:390},null,2)+'\n');
 console.log(JSON.stringify({visible,sent,statuses,cardsRemain:3},null,2));
} finally {
 if(ws) ws.close();
 browser.kill('SIGTERM');
 await Promise.race([new Promise(r=>browser.once('exit',r)),sleep(3000)]);
 if(browser.exitCode===null)browser.kill('SIGKILL');
}
