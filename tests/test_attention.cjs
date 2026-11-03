// 用轻量 DOM 替身验证提醒去重与状态切换，不触发真实 Mac 跳转。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const nodes = new Map();
const get = id => {
  if (!nodes.has(id)) nodes.set(id, {setAttribute(){},open:false, textContent:'', addEventListener(){}, showModal(){this.open=true; this.shown=(this.shown||0)+1;}, close(){this.open=false;}});
  return nodes.get(id);
};
const context = vm.createContext({document:{getElementById:get,hidden:true,addEventListener(){}}, navigator:{},sessionStorage:{getItem(){return '';}}, setInterval(){}, Date});
vm.runInContext(fs.readFileSync('web/app.js','utf8'), context);
const run = code => vm.runInContext(code, context);
run('updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,1);
run('dismissAttention(); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').open,false);
run('updateAttention(null,false); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,1);
run('updateAttention(null); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,2);
run('updateAttention(null,false)');
assert.equal(get('attention-dialog').open,false);
console.log('提醒首次弹出、关闭去重、断线和再次等待验证通过');

// 点击内容、按钮与内边距均跳转；遮罩和稍后处理必须排除。
run('var originalOpen = openConversation; var opened = []; openConversation = id => opened.push(id); updateAttention({threadId:"click-target",title:"点击测试"})');
const dialog = get('attention-dialog');
dialog.closest = () => null;
for (const area of ['标题','图标','正文','打开按钮','内边距']) {
  dialog.onclick({target:{closest:selector=>selector === '.attention-card' ? {} : null}});
}
assert.equal(run('opened.length'),5);
assert.ok(run('opened.every(id => id === "click-target")'));
dialog.onclick({target:dialog});
dialog.onclick({target:{closest:()=>null}});
assert.equal(run('opened.length'),5);
get('attention-dismiss').onclick();
assert.equal(dialog.open,false);
run('updateAttention(null); openConversation = originalOpen');


assert.equal(run("formatPlan('promax')"),'Pro 500');
assert.equal(run("formatPlan('custom')"),'custom');
assert.equal(run("formatPlan(null)"),'未知套餐');

const overview = run("taskOverview({state:'done',conversations:[{state:'running'},{state:'running'},{state:'done'}]})");
assert.equal(overview.state,'running');assert.equal(overview.counts.running,2);assert.equal(overview.counts.done,1);
assert.equal(run("taskOverview({conversations:[]}).state"),'unknown');

const mixed = run("taskOverview({conversations:[{state:'running',unread:true},{state:'done',unread:true}]})");
assert.equal(mixed.tasks.length,2);assert.equal(mixed.counts.running,1);assert.equal(mixed.counts.done,2);
assert.equal(run("taskOverview({conversations:[{state:'running',unread:false}]}).counts.done"),0);

// 同一行必须同时保留当前状态和独立未读标签，不能仅修复统计。
context.document.createElement = () => ({style:{},children:[],setAttribute(){},append(...items){this.children.push(...items);}});
for (const id of ['task-list','windows']) {
  get(id).replaceChildren = function(...items){this.children=items;};
  get(id).append = function(...items){this.children.push(...items);};
}
run("render({conversationsAvailable:true,conversations:[{title:'双状态',threadId:'a',state:'running',unread:true}],quotaAvailable:false})");
const row = get('task-list').children[0];
assert.equal(row.className,'task running');
assert.ok(row.children.some(node => node.textContent === '正在进行'));
assert.ok(row.children.some(node => node.className === 'unread-mark' && node.textContent === '完成未读'));
assert.ok(row.children.findIndex(node => node.className === 'unread-mark') < row.children.findIndex(node => node.className === 'badge'));
assert.equal(row.children.at(-1).className,'badge');
run("render({conversationsAvailable:true,conversations:[{title:'已读仍运行',threadId:'a',state:'running',unread:false}],quotaAvailable:false})");
assert.ok(!get('task-list').children[0].children.some(node => node.className === 'unread-mark'));

run("render({conversationsAvailable:true,conversations:[{title:'计时',threadId:'a',state:'running',elapsedSeconds:125}],quotaAvailable:false})");
assert.equal(get('task-list').children[0].children.at(-2).textContent,'02:05');
assert.equal(get('task-list').children[0].children.at(-1).textContent,'正在进行');

// 验证连接成功、失败及恢复时颜色状态跟随真实刷新结果变化。
Object.assign(context, {AbortController, setTimeout, clearTimeout});
context.document.hidden = false;
(async () => {
  run("token = 'test'");
  context.fetch = async () => ({ok:true,json:async()=>({servedAt:Date.now()/1000,conversations:[],conversationsAvailable:true})});
  await run('refresh()');
  assert.equal(get('connection').className,'connected');
  const success = context.fetch;
  context.fetch = async () => {throw new Error('offline');};
  await run('refresh()');
  assert.equal(get('connection').className,'disconnected');
  context.fetch = success;
  await run('refresh()');
  assert.equal(get('connection').className,'connected');
  run("token = ''");
  await run('refresh()');
  assert.equal(get('connection').className,'disconnected');
})().catch(error => {console.error(error);process.exitCode=1;});

assert.equal(run('taskDuration(125)'), '02:05');
assert.equal(run('taskDuration(3601)'), '1:00:01');
assert.equal(run('taskDuration(undefined)'), '');
assert.equal(run('taskDuration(-1)'), '');
