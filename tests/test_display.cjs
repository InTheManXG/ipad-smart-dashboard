// 验证常亮设置跨刷新恢复、不支持时置灰、申请失败可重试及全屏回退。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const nodes = new Map(), events = {}, eventOptions = {}, timers = new Map();
const get = id => {
  if (!nodes.has(id)) nodes.set(id, {
    textContent:'', open:false, hidden:id === 'display-options',
    attrs:id === 'more-settings' ? {'aria-expanded':'false'} : {},
    listeners:{}, listenerOptions:{}, children:[],
    setAttribute(key,value){this.attrs[key]=value;},
    addEventListener(name,listener,options){this.listeners[name]=listener;this.listenerOptions[name]=options;},
    contains(target){return target === this || this.children.includes(target);},
    focus(){this.focused=true;},
    showModal(){this.open=true;}, close(){this.open=false;},
    remove(){nodes.delete('wake-notice');}
  });
  return nodes.get(id);
};
let requests = 0, releases = 0, enter = 0, exit = 0, reloads = 0;
const notices = [], timeouts = new Map();
const document = {body:{append(node){notices.push(node);nodes.set(node.id,node);}},createElement(){return {setAttribute(){},remove(){nodes.delete(this.id);}};},hidden:false,getElementById:get,addEventListener(name, fn, options){events[name]=fn;eventOptions[name]=options;},fullscreenEnabled:true,documentElement:{async requestFullscreen(){enter++;}},async exitFullscreen(){exit++;}};
const navigator = {wakeLock:{async request(){requests++;let listener;return {addEventListener(_,fn){listener=fn;},async release(){releases++;listener?.();}};}}};
const storage = new Map();
const context = vm.createContext({document,navigator,location:{protocol:'https:',reload(){reloads++;}},localStorage:{getItem:key=>storage.get(key) || null,setItem:(key,value)=>storage.set(key,value),removeItem:key=>storage.delete(key)},sessionStorage:{getItem(){return '';}},setInterval(fn,ms){timers.set(ms,fn);},setTimeout(fn,ms){timeouts.set(ms,fn);return ms;},clearTimeout(id){timeouts.delete(id);},Date,fetch:async()=>({ok:false,status:401})});
vm.runInContext(fs.readFileSync('web/app.js','utf8'),context);
(async()=>{
  await new Promise(resolve=>setImmediate(resolve));
  // 不提供 Popover API，验证旧版 Safari 也能完整开关菜单。
  const menu = get('display-options'), trigger = get('more-settings');
  assert.equal(menu.hidden,true,'菜单初始隐藏');
  assert.equal(trigger.attrs['aria-expanded'],'false');
  trigger.onclick();
  assert.equal(menu.hidden,false,'点击菜单入口展开');
  assert.equal(trigger.attrs['aria-expanded'],'true');
  trigger.onclick();
  assert.equal(menu.hidden,true,'再次点击菜单入口收起');
  assert.equal(trigger.attrs['aria-expanded'],'false');
  assert.equal(menu.listenerOptions.click,true,'选项在捕获阶段收起，避免异步操作影响关闭');
  for (const id of ['connect','fullscreen','wake','refresh','reload']) {
    trigger.onclick();
    menu.listeners.click({target:{closest:() => get(id)}});
    assert.equal(menu.hidden,true,`${id} 菜单项点击后应立即收起`);
    assert.equal(trigger.attrs['aria-expanded'],'false');
  }
  trigger.onclick();
  menu.listeners.click({target:{closest:() => null}});
  assert.equal(menu.hidden,false,'菜单内非按钮区域不触发选项操作');
  assert.equal(eventOptions.pointerdown,true,'外部点击通过捕获阶段处理');
  menu.children.push(get('wake'));
  trigger.children.push({});
  for (const target of [menu, get('wake'), trigger, trigger.children[0]]) {
    events.pointerdown({target});
    assert.equal(menu.hidden,false,'菜单及入口内部按下不提前关闭');
  }
  events.pointerdown({target:{}});
  assert.equal(menu.hidden,true,'菜单外部按下收起');
  assert.equal(trigger.attrs['aria-expanded'],'false');
  trigger.onclick();
  events.keydown({key:'Enter'});
  assert.equal(menu.hidden,false,'其他按键不关闭菜单');
  events.keydown({key:'Escape'});
  assert.equal(menu.hidden,true,'Escape 收起菜单');
  assert.equal(trigger.attrs['aria-expanded'],'false');
  assert.equal(trigger.focused,true,'Escape 后焦点返回入口');
  get('reload').onclick();assert.equal(reloads,1);
  assert.equal(get('more-settings').attrs['data-wake-warning'],'false');
  assert.equal(requests,1);assert.equal(get('wake').textContent,'常亮已开启');
  assert.equal(get('wake').attrs['aria-pressed'],'true');
  assert.equal(get('wake').disabled,false,'已开启时仍可点击关闭');
  assert.equal(get('wake-dialog').open,false);
  await timers.get(5000)();
  events.pointerup({target:{closest(){return false;}}});
  events.visibilitychange();
  assert.equal(requests,1,'支持时首次打开自动开启，触摸、定时器和恢复前台不重复申请');
  await get('wake').onclick();assert.equal(releases,1);
  assert.equal(storage.get('keep-awake-enabled'),'false','手动关闭保存为关闭');
  events.pointerup({target:{closest(){return false;}}});assert.equal(requests,1);
  await get('wake').onclick();assert.equal(requests,2);
  assert.equal(storage.get('keep-awake-enabled'),'true','手动开启保存为开启');
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
  assert.equal(storage.get('keep-awake-enabled'),'true','申请失败不抹掉用户的开启偏好');
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
  // API 不再可用时置灰并清理开启意图，不弹错误或恢复遮罩。
  get('footer-note').textContent = '';
  delete navigator.wakeLock;
  vm.runInContext('showWakeState()',context);
  await get('wake').onclick();
  assert.equal(vm.runInContext('wantWake',context),false);
  assert.equal(get('wake-dialog').open,false);
  assert.equal(get('wake').textContent,'浏览器不支持常亮');
  assert.equal(get('wake').disabled,true);
  assert.equal(get('wake').attrs['aria-pressed'],'false');
  assert.equal(get('more-settings').attrs['data-wake-warning'],'false');
  assert.equal(get('footer-note').textContent,'','不支持时只在置灰选项说明原因');
  assert.equal(requests,5,'直接触发已禁用按钮也不会申请');
  navigator.wakeLock = {request:granted};
  vm.runInContext('showWakeState()',context);
  assert.equal(get('wake').disabled,false,'API 恢复后可手动开启');
  assert.equal(get('wake').textContent,'开启常亮');
  await get('wake').onclick();assert.equal(requests,6);
  assert.equal(get('footer-note').textContent,'');
  // 每次创建全新页面上下文，仅共享存储，模拟浏览器真正重新加载。
  async function loadDisplay(saved = new Map(), options = {}) {
    const initialNodes = new Map(), initialEvents = {}, initialTimers = [];
    const initialGet = id => {
      if (!initialNodes.has(id)) initialNodes.set(id, {textContent:'',open:false,attrs:{},setAttribute(key,value){this.attrs[key]=value;},addEventListener(){},showModal(){this.open=true;},close(){this.open=false;}});
      return initialNodes.get(id);
    };
    let initialRequests = 0;
    const initialNavigator = options.api === 'missing' ? {} : {wakeLock:{request:options.api === 'non-callable' ? null : async () => {
      initialRequests++;
      if (options.requestGate) await options.requestGate;
      if (options.denied) throw new Error('denied');
      let listener;
      return {addEventListener(_,fn){listener=fn;},async release(){listener?.();}};
    }}};
    const initialContext = vm.createContext({
      document:{hidden:false,getElementById:initialGet,addEventListener(name,fn){initialEvents[name]=fn;},documentElement:{}},
      navigator:initialNavigator,location:{protocol:'https:'},
      localStorage:{getItem:key=>saved.get(key) || null,setItem(key,value){if(options.writeDenied)throw new Error('storage denied');saved.set(key,value);}},setInterval(fn){initialTimers.push(fn);},Date
    });
    vm.runInContext(fs.readFileSync('web/app.js','utf8'),initialContext);
    await new Promise(resolve=>setImmediate(resolve));
    return {get:initialGet,context:initialContext,events:initialEvents,timers:initialTimers,get requests(){return initialRequests;}};
  }
  // 缺少可调用 API 时静默关闭；自动恢复被拒绝时保留偏好并等待一次用户手势。
  for (const mode of ['missing', 'non-callable', 'denied']) {
    const page = await loadDisplay(new Map(), {api:mode,denied:mode === 'denied'});
    assert.equal(vm.runInContext('wantWake',page.context),mode === 'denied',`${mode} 首次打开的常亮意图`);
    assert.equal(page.get('wake').attrs['aria-pressed'],'false');
    assert.equal(page.get('wake').textContent,mode === 'denied' ? '点击恢复常亮' : '浏览器不支持常亮');
    assert.equal(page.get('wake').disabled,mode !== 'denied','暂时申请失败仍可重试，不作为浏览器不支持');
    assert.equal(page.get('more-settings').attrs['data-wake-warning'],String(mode === 'denied'));
    assert.equal(page.get('wake-dialog').open,mode === 'denied','自动恢复被拒绝后提供手势恢复遮罩');
    if (mode === 'denied') assert.equal(vm.runInContext('wakeFailed',page.context),true);
    else {
      assert.equal(page.get('footer-note').textContent,'','不支持时静默关闭');
      await page.get('wake').onclick();
      assert.equal(page.get('wake-dialog').open,false,'直接触发置灰按钮不弹提示');
    }
    for (const tick of page.timers) await tick();
    page.events.pointerup({target:{closest(){return false;}}});
    page.events.visibilitychange();
    assert.equal(page.requests,mode === 'denied' ? 1 : 0,'不支持或申请失败后不自动重试');
  }
  const preference = new Map();
  let reloaded = await loadDisplay(preference);
  await reloaded.get('wake').onclick();
  assert.equal(preference.get('keep-awake-enabled'),'false');
  reloaded = await loadDisplay(preference);
  assert.equal(reloaded.requests,0,'保存关闭后，重新加载不会自动申请');
  assert.equal(reloaded.get('wake').attrs['aria-pressed'],'false');
  await reloaded.get('wake').onclick();
  assert.equal(preference.get('keep-awake-enabled'),'true');
  reloaded = await loadDisplay(preference);
  assert.equal(reloaded.requests,1,'保存开启后，重新加载自动重新申请系统锁');
  assert.equal(reloaded.get('wake').textContent,'常亮已开启');
  const unavailable = await loadDisplay(preference,{api:'missing'});
  assert.equal(unavailable.get('wake').disabled,true);
  assert.equal(preference.get('keep-awake-enabled'),'true','浏览器暂时不支持不覆盖已保存选择');
  const deniedOptions = {denied:true};
  const restore = await loadDisplay(preference,deniedOptions);
  assert.equal(restore.get('wake-dialog').open,true,'重载恢复失败时提示轻触恢复');
  assert.equal(preference.get('keep-awake-enabled'),'true');
  deniedOptions.denied = false;
  await restore.get('wake-dialog').onclick();
  assert.equal(restore.requests,2,'点击遮罩仅重试一次');
  assert.equal(restore.get('wake-dialog').open,false);
  assert.equal(restore.get('wake').textContent,'常亮已开启');
  // 系统可能在重载申请完成前切走页面，恢复提示只在回到前台后出现。
  let rejectHiddenRequest;
  const requestGate = new Promise((_,reject)=>{rejectHiddenRequest=reject;});
  const hiddenRestore = await loadDisplay(preference,{requestGate});
  hiddenRestore.context.document.hidden = true;
  rejectHiddenRequest(new Error('hidden'));
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(hiddenRestore.get('wake-dialog').open,false,'后台申请被拒时不弹恢复遮罩');
  hiddenRestore.context.document.hidden = false;
  hiddenRestore.events.visibilitychange();
  assert.equal(hiddenRestore.get('wake-dialog').open,true,'回到前台后显示保留设置的恢复提示');
  assert.equal(hiddenRestore.requests,1,'回到前台等待用户手势，不重复请求');
  const noStorage = await loadDisplay(new Map(),{writeDenied:true});
  await noStorage.get('wake').onclick();
  assert.equal(noStorage.get('wake').attrs['aria-pressed'],'false','存储写入失败仍可关闭当前常亮');
  assert.match(noStorage.get('footer-note').textContent,/无法保存/);
  await noStorage.get('wake').onclick();
  assert.equal(noStorage.get('wake').attrs['aria-pressed'],'true','存储写入失败仍可开启当前常亮');
  assert.equal(noStorage.requests,2);
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
    assert.equal(localGet('wake').textContent,'需 HTTPS 才能常亮');
    assert.equal(localGet('wake').disabled,true,'HTTP 下常亮选项置灰');
    assert.equal(localGet('more-settings').attrs['data-wake-warning'],'false');
    await localGet('wake').onclick();
    assert.equal(localGet('wake-dialog').open,false,'直接触发 HTTP 置灰按钮不弹提示');
    assert.equal(localGet('footer-note').textContent,'');
    assert.equal(localRequests,0);
    await localGet('wake-dialog').onclick();
    for (const tick of localTimers) await tick();
    localEvents.pointerup({target:{closest(){return false;}}});
    localEvents.visibilitychange();
    assert.equal(localRequests,0,'点击和恢复前台不能绕过连接限制');
    assert.equal(localGet('wake-dialog').open,false,'关闭后不反复弹出');
  }
  console.log('菜单选项自动收起、常亮设置跨刷新恢复、自动恢复手势提示、不支持时置灰、失败重试及全屏回退验证通过');
})().catch(error=>{console.error(error);process.exitCode=1;});
