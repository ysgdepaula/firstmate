import {spawn} from 'node:child_process';
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
const ev='/Users/ydeep/.no-mistakes/evidence/01M28Y4M6MGK0WWZGMMGZDW2E3';
const profile=resolve('.test-tmp/evidence-chrome');
const chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-features=GoogleUpdater','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
let ws;
try{
 let port;
 for(let i=0;i<100;i++){try{port=(await readFile(profile+'/DevToolsActivePort','utf8')).split('\n')[0];break;}catch{await delay(100);}}
 assert(port,'Chrome debugging port unavailable');
 const targets=await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
 ws=new WebSocket(targets.find(t=>t.type==='page').webSocketDebuggerUrl);
 await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j;});
 let id=0;const pending=new Map();
 ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){const p=pending.get(m.id);pending.delete(m.id);m.error?p.reject(m.error):p.resolve(m.result);}};
 const cmd=(method,params={})=>new Promise((resolve,reject)=>{const n=++id;pending.set(n,{resolve,reject});ws.send(JSON.stringify({id:n,method,params}));});
 const evaljs=async expression=>{const r=await cmd('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});assert(!r.exceptionDetails,JSON.stringify(r.exceptionDetails));return r.result.value;};
 await cmd('Page.enable');
 await cmd('Emulation.setDeviceMetricsOverride',{width:1280,height:1100,deviceScaleFactor:1,mobile:false});
 await cmd('Page.navigate',{url:'file://'+ev+'/projets.html'});
 for(let i=0;i<100;i++){if(await evaljs('!!document.querySelector("[data-decision]")'))break;await delay(100);}
 const cards=await evaljs(`Array.from(document.querySelectorAll('[data-decision]')).map(e=>({key:e.dataset.decision,nature:e.dataset.nature,question:e.querySelector('.q').textContent,ask:e.querySelector('.ask')?.textContent??null,buttons:Array.from(e.querySelectorAll('button')).map(b=>b.textContent)}))`);
 assert.equal(cards.length,3);
 assert.deepEqual(cards[0].buttons,['on y va','on ne le fait pas','pas maintenant','on en parle']);
 assert.equal(cards[1].ask,'je ne sais pas si c’est déjà fait');
 assert.deepEqual(cards[1].buttons,['je l’ai fait','pas encore','on en parle']);
 const screenshot=async name=>{await delay(200);const r=await cmd('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});await writeFile(ev+'/'+name,Buffer.from(r.data,'base64'));};
 await screenshot('projets-desktop.png');
 await cmd('Emulation.setDeviceMetricsOverride',{width:390,height:1250,deviceScaleFactor:1,mobile:true});
 await cmd('Page.reload');await delay(500);
 assert.equal(await evaljs('document.documentElement.scrollWidth <= window.innerWidth'),true);
 await screenshot('projets-phone.png');
 // In-memory transport double: exercise the page's actual click handlers without
 // delivering synthetic user decisions to any live Firstmate session.
 await evaljs(`window.__captured=[];window.lavish={queuePrompt(text,opts){window.__captured.push({text,data:opts.data,tag:opts.tag});},sendQueuedPrompts(){return Promise.resolve(true);}};`);
 const clicks=[];
 for(const [key,choice,nature] of [['torre-relance','on-ne-le-fait-pas','decision'],['torre-domaine','pas-encore','etat'],['torre-domaine','je-l-ai-fait','etat']]){
  const selector=`[data-decision="${key}"] [data-choice="${choice}"]`;
  await evaljs(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'center'})`);
  const rect=await evaljs(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
  await cmd('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...rect});
  await cmd('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...rect});await delay(50);
  const captured=await evaljs('window.__captured.at(-1)');
  assert.deepEqual(captured.data,{projet:'torre',decision:key,choix:choice,nature});
  const message=await evaljs(`document.querySelector('[data-decision="${key}"] .ok').textContent`);
  assert.match(message,/envoyé à firstmate/);
  clicks.push({...captured,message});
 }
 await screenshot('projets-phone-after-clicks.png');
 await writeFile(ev+'/browser-interactions.json',JSON.stringify({transport:'In-memory Lavish transport double; no live message sent. Chrome real pointer events.',cards,clicks},null,2));
 console.log('Chrome rendered composed cards at 1280 px and 390 px; real pointer clicks carried rejection and both status answers with the correct nature. Screenshots captured.');
}finally{ws?.close();chrome.kill('SIGKILL');}
