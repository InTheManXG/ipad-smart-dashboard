const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
function node() {
  return {children: [], textContent: '',open:false,showModal(){this.open=true;},close(){this.open=false;},addEventListener(){}, setAttribute(name,value){this[name]=value;}, append(...items){this.children.push(...items);}, replaceChildren(...items){this.children = items;},
    querySelectorAll(tag){return this.children.flatMap(child => [...(child.tag === tag ? [child] : []), ...child.querySelectorAll(tag)]);}};
}
const nodes = new Map(['console-actions', 'console-status', 'console-refresh','console-confirm','console-confirm-name','console-confirm-run','console-confirm-cancel'].map(id => [id, node()]));
const calls = [], timers = [], item = {id:'d46acd26-c9c3-4afc-9ac6-64b9088c7005',name:'<script>test</script>',kind:'script',state:'idle'};
let items = [item], status = 200;
const ctx = vm.createContext({
  document:{hidden:false,getElementById:id => nodes.get(id),createElement:tag => Object.assign(node(),{tag}),addEventListener(){}},
  window:{addEventListener(){}}, location:{hash:'#console'},
  localStorage:{getItem(){return 'test-only';}},sessionStorage:{getItem(){return null;}}, AbortSignal,
  setInterval(){},setTimeout(fn){timers.push(fn);},
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
  for (const [state,label] of [['idle','更新'],['running','更新中…'],['succeeded','已更新'],['failed','更新失败']]) {
    items = [{...item,kind:'subscription',name:'更新全部订阅',state}]; await run('loadConsole()');
    const row = list.children[0].children[1].children[0];
    const button = list.querySelectorAll('button')[0];
    assert.equal(row.tag,'div','订阅行不作为可点击卡片');
    assert.equal(row.onclick,undefined,'名称和空白不触发更新');
    assert.equal(row.children[0].children[0].textContent,'更新全部订阅');
    assert.equal(button.textContent,state === 'running' ? '更新中…' : '更新');
    assert.equal(button['aria-label'],'更新：更新全部订阅','独立按钮包含订阅名称以供读屏区分');
    assert.equal(row.children[0].children[1]?.textContent,state === 'idle' ? undefined : label);
    assert.equal(button.disabled,state === 'running');
  }
  list.querySelectorAll('button')[0].onclick();
  assert.equal(nodes.get('console-confirm').open,true,'独立更新按钮必须先确认');
  nodes.get('console-confirm-cancel').onclick();
  assert.ok(!fs.readFileSync('web/index.html','utf8').includes('id="update-all-subscriptions"'),'网页不再包含固定订阅入口');
  assert.ok(!fs.readFileSync('web/index.html','utf8').includes('src="./subscriptions.js"'));
  status=401;await run('loadConsole()');
  assert.equal(list.children.length,0,'撤销后清除可执行卡片');
  assert.match(nodes.get('console-status').textContent,/重新配对/);
  status=200;items=[];await run('loadConsole()');
  assert.match(list.children[0].textContent,/Mac App/);
  console.log('快捷控制台渲染、确认、仅 ID 执行、重复点击、结果和失效状态通过');
})().catch(error => {console.error(error);process.exitCode=1;});
