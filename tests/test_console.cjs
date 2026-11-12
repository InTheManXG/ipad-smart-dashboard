const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
function node() {
  return {children: [], textContent: '',open:false,showModal(){this.open=true;},close(){this.open=false;},addEventListener(){}, setAttribute(name,value){this[name]=value;}, append(...items){this.children.push(...items);}, replaceChildren(...items){this.children = items;},
    querySelectorAll(tag){return this.children.flatMap(child => [...(child.tag === tag ? [child] : []), ...child.querySelectorAll(tag)]);}};
}
const nodes = new Map(['console-actions', 'console-status', 'console-refresh','console-confirm','console-confirm-name','console-confirm-run','console-confirm-cancel'].map(id => [id, node()]));
const pages = {clientWidth:1024,scrollLeft:1024};
const calls = [], timers = [], intervals = [], item = {id:'d46acd26-c9c3-4afc-9ac6-64b9088c7005',name:'<script>test</script>',kind:'script',state:'idle'};
let items = [item], status = 200;
const ctx = vm.createContext({
  document:{hidden:false,querySelector(){return pages;},getElementById:id => nodes.get(id),createElement:tag => Object.assign(node(),{tag}),addEventListener(){}},
  window:{addEventListener(){}}, location:{hash:'#console'},
  localStorage:{getItem(){return 'test-only';}},sessionStorage:{getItem(){return null;}}, AbortSignal,
  setInterval(fn){intervals.push(fn);},setTimeout(fn){timers.push(fn);},
  fetch:async (path, options) => {calls.push({path,options}); return {ok:status===200,status,json:async()=>options.method==='POST'?{ok:true}:items};}
});
const run = code => vm.runInContext(code,ctx);
vm.runInContext(fs.readFileSync('web/console.js','utf8'), ctx);
(async () => {
  await new Promise(setImmediate);
  const list = nodes.get('console-actions');
  assert.equal(list.querySelectorAll('button')[0].children[1].textContent,item.name,'名称按文本呈现');
  assert.equal(list.querySelectorAll('button')[0].disabled,false);
  await run('requestConsoleAction('+JSON.stringify(item)+')');
  assert.equal(nodes.get('console-confirm').open,true);
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
  items = [Object.assign({},item,{state:'running'})]; timers.shift()(); await new Promise(setImmediate);
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
  assert.equal(list.children[0].children[1].children[0].children[2].textContent,'暂无更新记录','旧版或无历史快照不虚构时间');
  for (const [state,label] of [['idle','更新'],['running','更新中…'],['succeeded','已更新'],['failed','更新失败']]) {
    items = [{...item,kind:'subscription',name:'更新全部订阅',state}]; await run('loadConsole()');
    const row = list.children[0].children[1].children[0];
    const button = list.querySelectorAll('button')[0];
    assert.equal(row.tag,'div','订阅行不作为可点击卡片');
    assert.equal(row.onclick,undefined,'名称和空白不触发更新');
    assert.equal(row.children[0].children[0].textContent,'更新全部订阅');
    assert.equal(button.textContent,state === 'running' ? '更新中…' : '更新');
    assert.equal(button['aria-label'],'更新：更新全部订阅','独立按钮包含订阅名称以供读屏区分');
    assert.equal(row.children[0].children[1]?.textContent,['idle','running'].includes(state) ? undefined : label);
    assert.equal(button.disabled,state === 'running');
  }
  list.querySelectorAll('button')[0].onclick();
  assert.equal(nodes.get('console-confirm').open,true,'独立更新按钮必须先确认');
  nodes.get('console-confirm-cancel').onclick();
  // 手势只改变滚动位置，网址仍是首页；轮询必须跟随实际可见页。
  ctx.location.hash = '#home'; pages.scrollLeft = 0;
  items = [{...item,kind:'subscription',name:'更新全部订阅',state:'idle'}];
  await run('loadConsole()');
  list.querySelectorAll('button')[0].onclick();
  nodes.get('console-confirm-run').onclick(); await new Promise(setImmediate);
  assert.equal(calls.filter(call=>call.options.method==='POST').length,2,'订阅确认后只提交一次');
  items = [{...items[0],state:'running'}]; timers.shift()(); await new Promise(setImmediate);
  const subscriptionRow = () => list.children[0].children[1].children[0];
  assert.equal(subscriptionRow().children[0].children.length,1,'更新中只在按钮显示一次');
  assert.equal(list.querySelectorAll('button')[0].textContent,'更新中…');
  assert.equal(list.querySelectorAll('button')[0].disabled,true);
  items = [{...items[0],state:'succeeded'}];
  intervals[0](); await new Promise(setImmediate);
  assert.equal(subscriptionRow().children[0].children[1]?.textContent,'已更新','完成后定时拉取新结果');
  assert.equal(list.querySelectorAll('button')[0].textContent,'更新');
  assert.equal(list.querySelectorAll('button')[0].disabled,false,'自动恢复更新按钮');
  assert.equal(calls.filter(call=>call.options.method==='POST').length,2,'自动刷新不会再次提交更新');
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
    const updated = subscriptionRow().children[2];
    assert.equal(updated.textContent,'上次更新');
    assert.equal(updated.children[0].tag,'time');
    assert.equal(updated.children[0].dateTime,'2026-11-12T10:30:00.000Z','时间来自真实快照，刷新和失败不覆盖');
    assert.ok(updated.children[0].textContent.includes('2026'));
  }
  assert.ok(!fs.readFileSync('web/index.html','utf8').includes('id="update-all-subscriptions"'),'网页不再包含固定订阅入口');
  assert.ok(!fs.readFileSync('web/index.html','utf8').includes('src="./subscriptions.js"'));
  status=401;await run('loadConsole()');
  assert.equal(list.children.length,0,'撤销后清除可执行卡片');
  assert.match(nodes.get('console-status').textContent,/重新配对/);
  status=200;items=[];await run('loadConsole()');
  assert.match(list.children[0].textContent,/Mac App/);
  console.log('快捷控制台渲染、确认、仅 ID 执行、重复点击、结果和失效状态通过');
})().catch(error => {console.error(error);process.exitCode=1;});
