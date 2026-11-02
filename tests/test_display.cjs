// 验证默认常亮、用户关闭、恢复前台和全屏回退，不依赖真实屏幕锁。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const nodes = new Map(), events = {};
const get = id => {
  if (!nodes.has(id)) nodes.set(id,{textContent:'',setAttribute(){},addEventListener(){},showModal(){},close(){}});
  return nodes.get(id);
};
let requests = 0, releases = 0, enter = 0, exit = 0;
const document = {hidden:false,getElementById:get,addEventListener(name, fn){events[name]=fn;},fullscreenEnabled:true,documentElement:{async requestFullscreen(){enter++;}},async exitFullscreen(){exit++;}};
const navigator = {wakeLock:{async request(){requests++;let listener;return {addEventListener(_,fn){listener=fn;},async release(){releases++;listener?.();}};}}};
const context = vm.createContext({document,navigator,sessionStorage:{getItem(){return '';}},setInterval(){},Date});
vm.runInContext(fs.readFileSync('web/app.js','utf8'),context);
(async()=>{
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(requests,1);assert.equal(get('wake').textContent,'常亮已开启');
  await get('wake').onclick();assert.equal(releases,1);
  events.pointerup({target:{closest(){return false;}}});assert.equal(requests,1);
  await get('wake').onclick();assert.equal(requests,2);
  await get('fullscreen').onclick();assert.equal(enter,1);
  document.fullscreenElement={};await get('fullscreen').onclick();assert.equal(exit,1);
  document.fullscreenElement=null;document.fullscreenEnabled=false;
  await get('fullscreen').onclick();assert.match(get('footer-note').textContent,/添加到主屏幕/);
  document.hidden=true;await vm.runInContext('wakeLock.release()',context);
  document.hidden=false;events.visibilitychange();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(requests,3);
  console.log('默认常亮、关闭与恢复、全屏及回退提示验证通过');
})().catch(error=>{console.error(error);process.exitCode=1;});
