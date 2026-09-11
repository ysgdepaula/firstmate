import {spawn} from 'node:child_process';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const evidence='/Users/ydeep/.no-mistakes/evidence/01M298ZRRY4W20EE1Q7Q6N55TV';
const profile=resolve('.test-phase-tmp/cdp-profile-'+Date.now()); await mkdir(profile,{recursive:true});
const proc=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],{stdio:'ignore'});
let ws;
try {
 let port;
 for(let i=0;i<200;i++){try{port=(await readFile(profile+'/DevToolsActivePort','utf8')).split('\n')[0];break;}catch{} await new Promise(r=>setTimeout(r,100));}
 assert(port,'Chrome did not start');
 const pages=await (await fetch('http://127.0.0.1:'+port+'/json/list')).json();
 ws=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl); await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j});
 let id=0;const pending=new Map();ws.onmessage=e=>{let m=JSON.parse(e.data);if(m.id){let p=pending.get(m.id);pending.delete(m.id);m.error?p[1](Error(JSON.stringify(m.error))):p[0](m.result)}};
 const send=(method,params={})=>new Promise((r,j)=>{pending.set(++id,[r,j]);ws.send(JSON.stringify({id,method,params}))});
 const evaluate=async expression=>{let r=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});assert(!r.exceptionDetails,JSON.stringify(r.exceptionDetails));return r.result.value};
 await send('Page.enable');
 const results=[];
 for(const [name,width,height] of [['before',1440,1200],['after',1440,1200],['after',390,1300]]){
  await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
  await send('Page.navigate',{url:pathToFileURL(evidence+'/'+name+'.html').href});
  for(let i=0;i<100;i++){if(await evaluate('document.readyState==="complete" && !!document.querySelector(".you li")'))break;await new Promise(r=>setTimeout(r,100));}
  const visible=await evaluate(`({width:innerWidth,overflow:document.documentElement.scrollWidth>innerWidth,rows:[...document.querySelectorAll('.you li')].map(e=>({key:e.dataset.decision,nature:e.dataset.nature,question:e.querySelector('.q').textContent,choices:[...e.querySelectorAll('button')].map(b=>b.textContent)}))})`);
  if(!visible.rows.length) console.log(await evaluate('({url:location.href,body:document.body.innerText})')); assert.equal(visible.overflow,false);assert.equal(visible.rows.length,4);
  if(name==='after'){assert.deepEqual(visible.rows[0].choices,['on y va','on ne le fait pas','pas maintenant','on en parle']);assert(visible.rows[1].question.includes('je ne sais pas si c’est déjà fait'));}
  const shot=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
  await writeFile(`${evidence}/${name}-${width===390?'phone':'desktop'}.png`,Buffer.from(shot.data,'base64'));
  results.push({page:name,...visible});
 }
 // Capture the real rendered button handler at the Lavish delivery boundary.
 const clicks=await evaluate(`(() => {const captured=[];window.lavish={queuePrompt:(prompt,context)=>captured.push({prompt,data:context.data}),sendQueuedPrompts:()=>true};document.querySelector('[data-decision="torre-relance"] [data-choice="on-ne-le-fait-pas"]').click();document.querySelector('[data-decision="torre-domaine"] [data-choice="je-l-ai-fait"]').click();return {captured,messages:[...document.querySelectorAll('.you .ok')].map(e=>e.textContent)}})()`);
 assert.equal(clicks.captured[0].data.nature,'decision');assert.equal(clicks.captured[1].data.nature,'etat');assert(clicks.messages[0].includes('envoyé à firstmate'));assert(clicks.messages[1].includes('envoyé à firstmate'));
 await writeFile(evidence+'/browser-observations.json',JSON.stringify({surfaces:results,delivery:'Lavish API stub; no external message sent',clicks},null,2));
 console.log('Desktop before/after and 390px phone screenshots captured; visible choices, uncertainty admission, no overflow, and browser click payloads verified.');
} finally {ws?.close();proc.kill('SIGTERM');await new Promise(r=>{proc.once('exit',r);setTimeout(()=>{proc.kill('SIGKILL');r()},5000).unref()});}
