// 验证默认关闭、申请失败回退、用户开启后恢复及全屏回退，不依赖真实屏幕锁。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const nodes = new Map(), events = {}, timers = new Map();
const get = id => {
  if (!nodes.has(id)) nodes.set(id,{textContent:'',open:false,attrs:{},listeners:{},setAttribute(key,value){this.attrs[key]=value;},addEventListener(name,listener){this.listeners[name]=listener;},hidePopover(){this.popoverOpen=false;},showModal(){this.open=true;},close(){this.open=false;},remove(){nodes.delete('wake-notice');}});
  return nodes.get(id);
};
let requests = 0, releases = 0, enter = 0, exit = 0, reloads = 0;
const notices = [], timeouts = new Map();
const document = {body:{append(node){notices.push(node);nodes.set(node.id,node);}},createElement(){return {setAttribute(){},remove(){nodes.delete(this.id);}};},hidden:false,getElementById:get,addEventListener(name, fn){events[name]=fn;},fullscreenEnabled:true,documentElement:{async requestFullscreen(){enter++;}},async exitFullscreen(){exit++;}};
const navigator = {wakeLock:{async request(){requests++;let listener;return {addEventListener(_,fn){listener=fn;},async release(){releases++;listener?.();}};}}};
const context = vm.createContext({document,navigator,location:{protocol:'https:',reload(){reloads++;}},localStorage:{getItem(){return '';},setItem(){},removeItem(){}},sessionStorage:{getItem(){return '';}},setInterval(fn,ms){timers.set(ms,fn);},setTimeout(fn,ms){timeouts.set(ms,fn);return ms;},clearTimeout(id){timeouts.delete(id);},Date,fetch:async()=>({ok:false,status:401})});
vm.runInContext(fs.readFileSync('web/app.js','utf8'),context);
(async()=>{
  await new Promise(resolve=>setImmediate(resolve));
  const menu = get('display-options');
  for (const id of ['connect','fullscreen','wake','refresh','reload']) {
    menu.popoverOpen = true;
    menu.listeners.click({target:{closest:() => get(id)}});
    assert.equal(menu.popoverOpen,false,`${id} 菜单项点击后应立即收起`);
  }
  menu.popoverOpen = true;
  menu.listeners.click({target:{closest:() => null}});
  assert.equal(menu.popoverOpen,true,'菜单内非按钮区域不触发选项操作');
  get('reload').onclick();assert.equal(reloads,1);
  assert.equal(get('more-settings').attrs['data-wake-warning'],'false');
  assert.equal(requests,0);assert.equal(get('wake').textContent,'开启常亮');
  assert.equal(get('wake').attrs['aria-pressed'],'false');
  assert.equal(get('wake-dialog').open,false);
  await timers.get(5000)();
  events.pointerup({target:{closest(){return false;}}});
  events.visibilitychange();
  assert.equal(requests,0,'首次打开、触摸、定时器和恢复前台均不自动开启');
  await get('wake').onclick();assert.equal(requests,1);
  assert.equal(get('wake').textContent,'常亮已开启');
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
  assert.equal(get('more-settings').attrs['data-wake-warning'],'false');
  await vm.runInContext('wakeLock.release()',context);
  assert.equal(get('wake').attrs['aria-pressed'],'false');
  assert.equal(get('more-settings').attrs['data-wake-warning'],'true');
  await timers.get(5000)();assert.equal(requests,3);
  assert.equal(get('wake-dialog').open,true);
  await get('wake-dialog').onclick();assert.equal(requests,4);
  assert.equal(get('wake-dialog').open,false);
  assert.equal(get('wake').textContent,'常亮已开启');
  assert.match(get('footer-note').textContent,/添加到主屏幕/);
  assert.equal(nodes.has('wake-notice'),false);
  await timers.get(5000)();assert.equal(requests,4);
  await get('wake').onclick();
  await timers.get(5000)();assert.equal(requests,4);
  assert.equal(get('more-settings').attrs['data-wake-warning'],'false');
  const granted = navigator.wakeLock.request;
  let denied = 0;
  navigator.wakeLock.request = async () => {denied++;throw new Error('denied');};
  await get('wake').onclick();
  assert.equal(get('wake').attrs['aria-pressed'],'false');
  assert.equal(get('more-settings').attrs['data-wake-warning'],'false');
  assert.equal(get('wake').textContent,'开启常亮');
  assert.equal(get('wake').disabled,false);
  assert.match(get('footer-note').textContent,/申请失败，已关闭/);
  assert.equal(get('wake-dialog').open,false);
  assert.equal(vm.runInContext('wantWake',context),false);
  await timers.get(5000)();assert.equal(denied,1);
  events.pointerup({target:{closest(){return false;}}});
  events.visibilitychange();
  assert.equal(denied,1);
  navigator.wakeLock.request = granted;
  await timers.get(5000)();assert.equal(requests,4);
  await get('wake').onclick();assert.equal(requests,5);
  assert.equal(get('wake-dialog').open,false);
  assert.equal(get('wake').attrs['aria-pressed'],'true');
  assert.equal(get('wake').textContent,'常亮已开启');
  assert.equal(get('footer-note').textContent,'','手动重试成功后清除常亮失败提示');
  // 用户恢复已中断的常亮时，申请再次失败也要关闭遮罩并撤销开启意图。
  await vm.runInContext('wakeLock.release()',context);
  assert.equal(get('wake-dialog').open,true);
  navigator.wakeLock.request = async () => {denied++;throw new Error('denied');};
  await get('wake-dialog').onclick();
  assert.equal(get('wake-dialog').open,false);
  assert.equal(get('wake').textContent,'开启常亮');
  assert.equal(get('wake').attrs['aria-pressed'],'false');
  assert.equal(get('more-settings').attrs['data-wake-warning'],'false');
  await timers.get(5000)();
  events.visibilitychange();
  assert.equal(denied,2,'恢复申请失败后也不自动重试');
  // 不支持 API 的浏览器也必须回到相同的关闭状态。
  delete navigator.wakeLock;
  await get('wake').onclick();
  assert.equal(vm.runInContext('wantWake',context),false);
  assert.equal(get('wake-dialog').open,false);
  assert.equal(get('wake').textContent,'开启常亮');
  assert.equal(get('wake').attrs['aria-pressed'],'false');
  assert.equal(get('more-settings').attrs['data-wake-warning'],'false');
  assert.match(get('footer-note').textContent,/不支持，已关闭/);
  navigator.wakeLock = {request:granted};
  await get('wake').onclick();assert.equal(requests,6);
  assert.equal(get('footer-note').textContent,'');
  // HTTP 回环地址即使被浏览器视为安全上下文，也遵循产品的 HTTPS 常亮规则。
  for (const hostname of ['192.168.1.10', '127.0.0.1', 'localhost']) {
    const localNodes = new Map(), localEvents = {}, localTimers = [];
    const localGet = id => {
      if (!localNodes.has(id)) localNodes.set(id, {textContent:'',open:false,attrs:{},setAttribute(key,value){this.attrs[key]=value;},addEventListener(){},showModal(){this.open=true;},close(){this.open=false;}});
      return localNodes.get(id);
    };
    let localRequests = 0;
    const localContext = vm.createContext({
      document:{hidden:false,getElementById:localGet,addEventListener(name,fn){localEvents[name]=fn;},documentElement:{}},
      navigator:{wakeLock:{async request(){localRequests++;throw new Error('HTTP 不应申请常亮');}}},
      location:{protocol:'http:',hostname},isSecureContext:hostname !== '192.168.1.10',
      localStorage:{getItem(){return '';}},setInterval(fn){localTimers.push(fn);},Date
    });
    vm.runInContext(fs.readFileSync('web/app.js','utf8'),localContext);
    assert.equal(localRequests,0,'HTTP 默认关闭常亮');
    assert.equal(localGet('wake-dialog').open,false,'HTTP 首次打开不遮挡看板');
    assert.equal(localGet('wake').attrs['aria-pressed'],'false');
    assert.equal(localGet('wake').textContent,'开启常亮');
    assert.equal(localGet('more-settings').attrs['data-wake-warning'],'false');
    await localGet('wake').onclick();
    assert.equal(localGet('wake-dialog').open,true,'用户点击后才显示限制原因');
    assert.equal(localGet('wake-heading').textContent,'非 HTTPS 链接不支持常亮');
    assert.equal(localRequests,0);
    await localGet('wake-dialog').onclick();
    for (const tick of localTimers) await tick();
    localEvents.pointerup({target:{closest(){return false;}}});
    localEvents.visibilitychange();
    assert.equal(localRequests,0,'点击和恢复前台不能绕过连接限制');
    assert.equal(localGet('wake-dialog').open,false,'关闭后不反复弹出');
  }
  console.log('菜单选项自动收起、常亮默认关闭、失败回退、手动重试、关闭与恢复、全屏及回退提示验证通过');
})().catch(error=>{console.error(error);process.exitCode=1;});
