const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
function node() {
  return {children: [], textContent: '',open:false,showModal(){this.open=true;},close(){this.open=false;},addEventListener(){},focus(){this.focused=true;}, setAttribute(name,value){this[name]=value;}, append(...items){this.children.push(...items);}, replaceChildren(...items){this.children = items;},
    querySelectorAll(tag){return this.children.flatMap(child => [...(child.tag === tag ? [child] : []), ...child.querySelectorAll(tag)]);}};
}
const nodes = new Map(['console-actions', 'console-status', 'console-refresh','console-confirm','console-confirm-name','console-confirm-target','console-confirm-description','console-confirm-run','console-confirm-cancel'].map(id => [id, node()]));
const pages = {clientWidth:1024,scrollLeft:1024};
const calls = [], timers = [], intervals = [], item = {id:'d46acd26-c9c3-4afc-9ac6-64b9088c7005',name:'<script>test</script>',kind:'script',state:'idle'};
const events = {};
const permissionMessage = '控制台尚未允许此网页控制 Mac，请在 Mac「iPad 控制台 → 连接与配对」中开启「允许控制此 Mac」。';
let items = [item], status = 200, controlAllowed = true;
const ctx = vm.createContext({
  controlRequiredMessage:permissionMessage,
  document:{hidden:false,querySelector(){return pages;},getElementById:id => nodes.get(id),createElement:tag => Object.assign(node(),{tag}),addEventListener(){}},
  window:{addEventListener(name, callback){events[name] = callback;}}, location:{hash:'#console'},
  localStorage:{getItem(){return 'test-only';}},sessionStorage:{getItem(){return null;}}, AbortController,
  setInterval(fn){intervals.push(fn);},
  setTimeout(fn,delay){const timer={fn,delay};timers.push(timer);return timer;},
  clearTimeout(timer){const index=timers.indexOf(timer);if(index!==-1)timers.splice(index,1);},
  fetch:async (path, options) => {calls.push({path,options}); return {ok:status===200,status,json:async()=>options.method==='POST'?{ok:true}:path.endsWith('/permissions')?{controlAllowed}:items};}
});
const run = code => vm.runInContext(code,ctx);
const takeTimer = delay => {
  const index = timers.findIndex(timer=>timer.delay===delay);
  assert.notEqual(index,-1,`应安排 ${delay}ms 计时器`);
  return timers.splice(index,1)[0].fn;
};
vm.runInContext(fs.readFileSync('web/console.js','utf8'), ctx);
(async () => {
  await new Promise(setImmediate);
  assert.equal(run('typeof AbortSignal'),'undefined','旧 Safari 环境不依赖静态超时 API');
  assert.equal(timers.some(timer=>timer.delay===12000),false,'成功加载后释放请求超时计时器');
  const list = nodes.get('console-actions');
  assert.equal(list.querySelectorAll('button')[0].children[1].textContent,item.name,'名称按文本呈现');
  assert.equal(list.querySelectorAll('button')[0].disabled,false);
  await run('requestConsoleAction('+JSON.stringify(item)+')');
  assert.equal(nodes.get('console-confirm').open,true);
  assert.equal(nodes.get('console-confirm-name').textContent,`在 Mac 上执行「${item.name}」？`);
  assert.equal(nodes.get('console-confirm-target').hidden,true,'脚本确认不展示订阅目标区域');
  assert.equal(nodes.get('console-confirm-run').textContent,'执行');
  nodes.get('console-confirm-cancel').onclick();
  assert.equal(nodes.get('console-confirm').open,false);
  assert.equal(calls.filter(call=>call.options.method==='POST').length,0,'取消确认不会执行');
  const cardBefore = list.children[0];
  await run('loadConsole()');
  assert.equal(list.children[0],cardBefore,'数据不变保留按钮节点');
  await run('requestConsoleAction('+JSON.stringify(item)+')');
  nodes.get('console-confirm-run').onclick();
  await new Promise(setImmediate);
  await run('runConsoleAction('+JSON.stringify(item)+')');
  const posts = calls.filter(call=>call.options.method==='POST');
  assert.equal(posts.length,1,'提交期间重复点击只发送一次');
  assert.deepEqual(JSON.parse(posts[0].options.body),{id:item.id},'仅发送 ID');
  assert.equal(list.querySelectorAll('button')[0].disabled,true);
  items = [Object.assign({},item,{state:'running'})]; takeTimer(1200)(); await new Promise(setImmediate);
  assert.equal(list.querySelectorAll('button')[0].disabled,true,'运行中不重复执行');
  items = [Object.assign({},item,{state:'succeeded'})]; await run('loadConsole()');
  assert.equal(list.querySelectorAll('button')[0].children[2].textContent,'执行完成');
  assert.equal(list.querySelectorAll('button')[0].disabled,false);
  items = [Object.assign({},item,{id:'cmd',kind:'command'}), Object.assign({},item,{id:'app2',name:'第二应用',kind:'app',icon:'data:image/png;base64,iVBORw0KGgo='}), Object.assign({},item,{id:'app1',name:'第一应用',kind:'app'}), item];
  await run('loadConsole()');
  assert.deepEqual(list.children.map(group=>group.children[0].textContent),['应用','脚本','命令']);
  assert.deepEqual(list.children[0].querySelectorAll('button').map(button=>button.children[1].textContent),['第二应用','第一应用']);
  assert.equal(list.children[0].querySelectorAll('img')[0].src,'data:image/png;base64,iVBORw0KGgo=');
  for (const state of ['idle', 'succeeded', 'running', 'failed']) {
    items = [{...item, kind:'app', state}]; await run('loadConsole()');
    const button = list.querySelectorAll('button')[0];
    assert.equal(button.children.length, ['idle','succeeded'].includes(state) ? 2 : 3, '应用不展示打开文案，保留运行与失败反馈');
    assert.equal(button.disabled, state === 'running', '应用防重复执行保持有效');
  }
  items = [{...item,kind:'subscription',name:'更新全部订阅'}]; await run('loadConsole()');
  assert.equal(list.children[0].children[0].textContent,'订阅更新');
  assert.match(list.children[0].className, /console-group--subscriptions/);
  assert.equal(list.children[0].children[1].children[0].children[3].textContent,'暂无更新记录','旧版或无历史快照不虚构时间');
  for (const [state,label] of [['idle','更新'],['running','更新中…'],['succeeded','已更新'],['failed','更新失败']]) {
    items = [{...item,kind:'subscription',name:'更新全部订阅',state}]; await run('loadConsole()');
    const row = list.children[0].children[1].children[0];
    const button = list.querySelectorAll('button')[0];
    assert.equal(row.tag,'div','订阅行不作为可点击卡片');
    assert.equal(row.onclick,undefined,'名称和空白不触发更新');
    assert.equal(row.children[0].children[0].textContent,'更新全部订阅');
    assert.equal(button.textContent,state === 'running' ? '更新中…' : state === 'succeeded' ? '已更新' : '更新');
    assert.equal(button['aria-label'],`${button.textContent}：更新全部订阅`,'读屏能区分订阅与当前按钮状态');
    assert.equal(row.children[0].children.length,1,'名称区不再放失败提示');
    assert.equal(row.children[1],button,'按钮位于名称下方');
    assert.equal(row.children[2].textContent,state === 'failed' ? label : '','失败提示位于按钮之后、更新时间之前');
    assert.match(row.children[2].className,/console-subscription-feedback/,'所有状态保留相同的反馈位置');
    assert.equal(button.disabled,state === 'running');
  }
  list.querySelectorAll('button')[0].onclick();
  assert.equal(nodes.get('console-confirm').open,true,'独立更新按钮必须先确认');
  assert.equal(nodes.get('console-confirm').className,'console-confirm-subscription');
  assert.equal(nodes.get('console-confirm-name').textContent,'更新订阅？');
  assert.equal(nodes.get('console-confirm-target').textContent,'更新全部订阅');
  assert.equal(nodes.get('console-confirm-target').hidden,false);
  assert.equal(nodes.get('console-confirm-run').textContent,'确认更新');
  assert.equal(nodes.get('console-confirm-cancel').focused,true,'默认聚焦取消以避免误确认');
  nodes.get('console-confirm-cancel').onclick();
  const postsBeforeCancel = calls.filter(call=>call.options.method==='POST').length;
  await run('requestConsoleAction('+JSON.stringify(item)+')');
  assert.equal(nodes.get('console-confirm').className,'','切回脚本时恢复原确认样式');
  assert.equal(nodes.get('console-confirm-target').hidden,true);
  assert.equal(nodes.get('console-confirm-run').textContent,'执行');
  nodes.get('console-confirm-cancel').onclick();
  assert.equal(calls.filter(call=>call.options.method==='POST').length,postsBeforeCancel,'触摸取消不提交更新');
  while (timers.some(timer=>timer.delay===3000)) takeTimer(3000)();
  // 手势只改变滚动位置，网址仍是首页；轮询必须跟随实际可见页。
  ctx.location.hash = '#home'; pages.scrollLeft = 0;
  items = [{...item,kind:'subscription',name:'更新全部订阅',state:'idle'}];
  await run('loadConsole()');
  list.querySelectorAll('button')[0].onclick();
  nodes.get('console-confirm-run').onclick(); await new Promise(setImmediate);
  assert.equal(calls.filter(call=>call.options.method==='POST').length,2,'订阅确认后只提交一次');
  items = [{...items[0],state:'running'}]; takeTimer(1200)(); await new Promise(setImmediate);
  const subscriptionRow = () => list.children[0].children[1].children[0];
  assert.equal(subscriptionRow().children[0].children.length,1,'更新中只在按钮显示一次');
  assert.equal(list.querySelectorAll('button')[0].textContent,'更新中…');
  assert.equal(list.querySelectorAll('button')[0].disabled,true);
  items = [{...items[0],state:'succeeded'}];
  intervals[0](); await new Promise(setImmediate);
  assert.equal(subscriptionRow().children[0].children.length,1,'名称下不显示成功状态');
  assert.equal(list.querySelectorAll('button')[0].textContent,'已更新','完成后在按钮内反馈成功');
  assert.equal(list.querySelectorAll('button')[0].disabled,false,'自动恢复更新按钮');
  assert.equal(calls.filter(call=>call.options.method==='POST').length,2,'自动刷新不会再次提交更新');
  const firstReset = takeTimer(3000);
  intervals[0](); await new Promise(setImmediate);
  assert.equal(list.querySelectorAll('button')[0].textContent,'已更新');
  assert.equal(timers.filter(timer=>timer.delay===3000).length,0,'相同成功快照不续期');
  firstReset(); await new Promise(setImmediate);
  assert.equal(list.querySelectorAll('button')[0].textContent,'更新','三秒后自动恢复更新按钮');
  intervals[0](); await new Promise(setImmediate);
  assert.equal(list.querySelectorAll('button')[0].textContent,'更新','常驻成功状态不会反复闪提示');
  // 即使漏掉 running，只要成功时间改变，仍应显示本轮反馈。
  items = [{...items[0],lastUpdatedAt:1800000000}]; intervals[0](); await new Promise(setImmediate);
  assert.equal(list.querySelectorAll('button')[0].textContent,'已更新');
  const oldReset = takeTimer(3000);
  items = [{...items[0],state:'running'}]; intervals[0](); await new Promise(setImmediate);
  assert.equal(list.querySelectorAll('button')[0].textContent,'更新中…');
  items = [{...items[0],state:'succeeded',lastUpdatedAt:1800000010}]; intervals[0](); await new Promise(setImmediate);
  const latestReset = takeTimer(3000);
  oldReset(); await new Promise(setImmediate);
  assert.equal(list.querySelectorAll('button')[0].textContent,'已更新','上一轮计时器不能清除新成功反馈');
  latestReset(); await new Promise(setImmediate);
  assert.equal(list.querySelectorAll('button')[0].textContent,'更新');
  assert.equal(subscriptionRow().children[3].children[0].dateTime,new Date(1800000010000).toISOString(),'恢复按钮不清除上次更新时间');
  items = [{...items[0],id:'historical'}]; await run('loadConsole()');
  assert.equal(list.querySelectorAll('button')[0].textContent,'更新','首次读到历史成功不会当成新完成');

  ctx.location.hash = '#console'; pages.scrollLeft = pages.clientWidth;
  let requestCount = calls.length; intervals[0](); await new Promise(setImmediate);
  assert.equal(calls.length,requestCount,'网址未变但滑离控制台时停止轮询');
  pages.scrollLeft = 0; ctx.document.hidden = true;
  requestCount = calls.length; intervals[0](); await new Promise(setImmediate);
  assert.equal(calls.length,requestCount,'网页隐藏时不轮询');
  ctx.document.hidden = false;
  const updatedAt = Date.parse('2026-11-12T10:30:00Z') / 1000;
  for (const state of ['idle','running','succeeded','failed']) {
    items = [{...item,kind:'subscription',state,lastUpdatedAt:updatedAt}]; await run('loadConsole()');
    const updated = subscriptionRow().children[3];
    assert.equal(updated.textContent,'上次更新');
    assert.equal(updated.children[0].tag,'time');
    assert.equal(updated.children[0].dateTime,'2026-11-12T10:30:00.000Z','时间来自真实快照，刷新和失败不覆盖');
    assert.ok(updated.children[0].textContent.includes('2026'));
  }
  assert.ok(!fs.readFileSync('web/index.html','utf8').includes('id="update-all-subscriptions"'),'网页不再包含固定订阅入口');
  assert.ok(!fs.readFileSync('web/index.html','utf8').includes('src="./subscriptions.js"'));
  controlAllowed=false;status=200;items=[item];await run('loadConsole()');
  assert.equal(list.querySelectorAll('button')[0].disabled,true,'只读会话仍显示卡片但禁用执行');
  const postsBefore=calls.filter(call=>call.options.method==='POST').length;
  await run('requestConsoleAction('+JSON.stringify(item)+')');
  assert.equal(calls.filter(call=>call.options.method==='POST').length,postsBefore,'只读会话不能提交执行');
  assert.equal(nodes.get('console-status').textContent,permissionMessage);
  for (const kind of ['app','script','command','subscription']) {
    await run('requestConsoleAction('+JSON.stringify({...item,kind})+')');
    await run('runConsoleAction('+JSON.stringify({...item,kind})+')');
    assert.equal(nodes.get('console-status').textContent,permissionMessage);
  }
  assert.equal(calls.filter(call=>call.options.method==='POST').length,postsBefore,'所有只读入口禁止提交');
  controlAllowed=true;await run('loadConsole()');
  assert.equal(nodes.get('console-status').textContent,'','授权恢复后不再保留权限提示');
  await run('requestConsoleAction('+JSON.stringify(item)+')');
  assert.equal(nodes.get('console-confirm').open,true);
  controlAllowed=false;await run('loadConsole()');
  assert.equal(nodes.get('console-confirm').open,false,'撤权后关闭待执行确认框');
  assert.equal(nodes.get('console-confirm-run').disabled,true);
  assert.equal(run('consoleSelection'),null);
  // 请求发出后被服务端拒绝时，全部快捷类型都显示相同指引。
  for (const kind of ['app','script','command','subscription']) {
    controlAllowed=true;status=200;await run('loadConsole()');
    status=403;await run('runConsoleAction('+JSON.stringify({...item,kind})+')');
    assert.equal(nodes.get('console-status').textContent,permissionMessage);
    assert.ok(list.querySelectorAll('button').every(button=>button.disabled));
  }
  // 权限接口异常无法确定是否获准，不能错误提示用户尚未授权。
  status=503;requestCount=calls.length;await run('loadConsole()');
  assert.match(nodes.get('console-status').textContent,/Mac 未连接/);
  assert.notEqual(nodes.get('console-status').textContent,permissionMessage);
  assert.equal(calls.length,requestCount+1,'权限接口失败后不继续伪装成可用列表');
  controlAllowed=true;
  status=401;await run('loadConsole()');
  assert.equal(list.children.length,0,'撤销后清除可执行卡片');
  assert.match(nodes.get('console-status').textContent,/重新配对/);
  status=200;items=[];await run('loadConsole()');
  assert.match(list.children[0].textContent,/Mac App/);

  // 请求和响应体共用超时边界，所有结束路径都应释放计时器。
  const originalFetch = ctx.fetch;
  await run("consoleRequest('./api/console')");
  assert.equal(timers.some(timer=>timer.delay===12000),false,'请求成功后清理超时');
  status=503;
  await assert.rejects(run("consoleRequest('./api/console')"),/Mac 未连接/);
  assert.equal(timers.some(timer=>timer.delay===12000),false,'HTTP 失败后清理超时');
  status=200;
  ctx.fetch = async () => {throw new Error('network offline');};
  await assert.rejects(run("consoleRequest('./api/console')"),/network offline/);
  assert.equal(timers.some(timer=>timer.delay===12000),false,'网络失败后清理超时');
  ctx.fetch = async () => ({ok:true,status:200,json:async()=>{throw new SyntaxError('bad json');}});
  await assert.rejects(run("consoleRequest('./api/console')"),/bad json/);
  assert.equal(timers.some(timer=>timer.delay===12000),false,'响应解析失败后清理超时');
  ctx.fetch = async (path,{signal}) => ({ok:true,status:200,json:()=>new Promise((resolve,reject)=>{
    signal.addEventListener('abort',()=>reject(Object.assign(new Error('aborted'),{name:'AbortError'})),{once:true});
  })});
  const pendingBody = run("consoleRequest('./api/console')");
  await new Promise(setImmediate);
  assert.equal(timers.filter(timer=>timer.delay===12000).length,1,'读取响应体时保留超时保护');
  takeTimer(12000)();
  await assert.rejects(pendingBody,error=>error.name==='TimeoutError');
  assert.equal(timers.some(timer=>timer.delay===12000),false,'响应体超时后清理计时器');
  ctx.fetch = originalFetch;
  items=[item];await run('loadConsole()');
  const postsBeforeTimeout = calls.filter(call=>call.options.method==='POST').length;
  ctx.fetch = async (path,options) => {
    if (options.method !== 'POST') return originalFetch(path,options);
    calls.push({path,options});
    return new Promise((resolve,reject)=>{
      options.signal.addEventListener('abort',()=>reject(Object.assign(new Error('aborted'),{name:'AbortError'})),{once:true});
    });
  };
  const pendingSubmit = run('runConsoleAction('+JSON.stringify(item)+')');
  await new Promise(setImmediate);
  takeTimer(12000)();
  await pendingSubmit;
  assert.match(nodes.get('console-status').textContent,/请求超时，执行结果未确认/);
  assert.equal(run('consoleSubmitting'),false,'提交超时后解除提交中状态');
  assert.equal(timers.some(timer=>timer.delay===12000),false,'提交超时后清理计时器');
  assert.equal(timers.some(timer=>timer.delay===1200),false,'提交超时不安排成功后的自动刷新');
  intervals[0]();await new Promise(setImmediate);
  assert.equal(calls.filter(call=>call.options.method==='POST').length,postsBeforeTimeout+1,'超时后轮询只读状态，不重复提交');
  ctx.fetch = originalFetch;
  items=[item];await run('loadConsole()');
  await run('requestConsoleAction('+JSON.stringify(item)+')');
  assert.equal(nodes.get('console-confirm').open,true);
  let resolveLate;
  ctx.fetch = async path => path.endsWith('/permissions') ? {ok:true,json:async()=>({controlAllowed:true})} : new Promise(resolve => {resolveLate=resolve;});
  const lateLoad = run('loadConsole()'); await new Promise(setImmediate);
  events['pairing-invalid']();
  assert.equal(nodes.get('console-confirm').open,false,'统一失效关闭已开的确认框');
  assert.equal(nodes.get('console-confirm-name').textContent,'','统一失效清理私密名称');
  resolveLate({ok:true,json:async()=>[item]}); await lateLoad;
  assert.equal(list.children.length,0,'失效前开始的迟到响应不能重绘历史卡片');
  assert.equal(run('consoleSelection'),null,'失效后清除待执行项目');
  console.log('快捷控制台兼容超时、计时器清理、不重复提交、渲染、确认及失效状态通过');
})().catch(error => {console.error(error);process.exitCode=1;});
