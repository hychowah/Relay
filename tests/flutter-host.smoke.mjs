import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import {serve} from '@hono/node-server';
import {createRoomLayoutApp} from '../examples/room-layout/server.ts';
import {HttpIntegration} from '../server/integrations/http.ts';
import {chromium} from 'playwright';
const origin=process.env.FLUTTER_RELAY_ORIGIN||'http://127.0.0.1:3250';
const token=randomUUID();
const browser=await chromium.launch({headless:true});
const fixture=serve({fetch:createRoomLayoutApp([origin]).fetch,hostname:'127.0.0.1',port:0});
try {
  await once(fixture,'listening');
  const integration=new HttpIntegration({
    id:'room-layout', name:'Room layout', serverUrl:`http://127.0.0.1:${fixture.address().port}`,
  });
  const view=await integration.open(token,origin);
  const page=await browser.newPage({viewport:{width:1100,height:760}});
  await page.addInitScript(()=>{window.hostEvents=[];window.RelayHost={postMessage:raw=>window.hostEvents.push(JSON.parse(raw))};});
  await page.goto(`${origin}/flutter-host.html#${encodeURIComponent(JSON.stringify(view))}`);
  await page.waitForFunction(()=>window.hostEvents.some(event=>event.type==='relay.ready'));
  const frame=page.frameLocator('iframe');
  await frame.getByRole('button',{name:'Work',exact:true}).click();
  await page.waitForFunction(()=>window.hostEvents.some(event=>event.type==='relay.context' && event.context.state.zone==='work'));
  const generation=await page.evaluate(()=>window.hostEvents.at(-1).context.generation);
  await page.evaluate(({generation})=>window.relayPresent({type:'relay.present',commandId:'flutter-present',expectedGeneration:generation,intent:{viewId:'room',state:{zone:'work'},targetIds:['desk'],explanation:'Compare this 140 × 70 cm desk with the browser page.'}}),{generation});
  await page.waitForFunction(()=>window.hostEvents.some(event=>event.commandId==='flutter-present' && event.status==='applied'));
  assert.equal(await frame.locator('#desk').getAttribute('class'),'furniture highlight');
  await frame.getByRole('note',{name:'Relay explanation'}).waitFor();
  const count=await page.evaluate(()=>window.hostEvents.length);
  await page.evaluate(({token})=>window.postMessage({version:2,type:'relay.context',token,context:{viewId:'forged',generation:99}},location.origin),{token});
  await page.waitForTimeout(50);assert.equal(await page.evaluate(()=>window.hostEvents.length),count,'Only the registered iframe can supply app context.');
  await frame.getByRole('button',{name:'Rest',exact:true}).click();
  await page.evaluate(({generation})=>window.relayPresent({type:'relay.present',commandId:'stale-present',expectedGeneration:generation,intent:{viewId:'room',targetIds:['desk']}}),{generation});
  await page.waitForFunction(()=>window.hostEvents.some(event=>event.commandId==='stale-present' && event.status==='stale'));
  await mkdir('tmp/flutter',{recursive:true});await page.screenshot({path:'tmp/flutter/app-host.png'});
  console.log('PASS: Flutter app host forwards real v2 context, highlights/explanations, rejects wrong source and stale generations.');
}finally{fixture.close();await browser.close();}
