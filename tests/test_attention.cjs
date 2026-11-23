// 用轻量 DOM 替身验证提醒去重与状态切换，不触发真实 Mac 跳转。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync('web/app.js','utf8');
function page({storage = new Map(), failAttentionStorage = false} = {}) {
  const nodes = new Map();
  const get = id => {
    if (!nodes.has(id)) nodes.set(id, {
      style:{}, children:[], listeners:{}, setAttribute(){}, open:false, textContent:'',
      addEventListener(name, callback){this.listeners[name] = callback;},
      showModal(){this.open=true; this.shown=(this.shown||0)+1;}, close(){this.open=false;},
      replaceChildren(...items){this.children=items;}, append(...items){this.children.push(...items);}
    });
    return nodes.get(id);
  };
  const guardStorage = key => { if (failAttentionStorage && key === 'dismissed-attention-v1') throw new Error('storage unavailable'); };
  const context = vm.createContext({
    document:{getElementById:get, hidden:true, addEventListener(){},createElement(){return {style:{},children:[],setAttribute(){},append(...items){this.children.push(...items);}};}},
    navigator:{}, localStorage:{
      getItem(key){guardStorage(key);return storage.get(key) || null;},
      setItem(key,value){guardStorage(key);storage.set(key,value);},
      removeItem(key){guardStorage(key);storage.delete(key);}
    }, sessionStorage:{getItem(){return '';}}, window:{dispatchEvent(){}}, Event,
    AbortController, setTimeout, clearTimeout, setInterval(){}, Date,fetch:async()=>({ok:false,status:401})
  });
  vm.runInContext(source, context);
  return {nodes, get, context, storage, run:code => vm.runInContext(code, context)};
}
const {get, context, run} = page();
run('controlAllowed=true; updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,1);
run('dismissAttention(); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').open,false);
run('updateAttention(null,false); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,1);
run('updateAttention(null); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,2);
run('updateAttention(null,false)');
assert.equal(get('attention-dialog').open,false);

// 使用新页面上下文读取相同浏览器存储，真实模拟刷新后的提醒恢复。
const storage = new Map(), firstPage = page({storage});
const prompt = (target, threadId, requestIds) => target.run(`controlAllowed=true; updateAttention(${JSON.stringify({threadId, title:'待处理', requestIds})})`);
prompt(firstPage,'persisted',['question-1','question-2']);
firstPage.get('attention-dismiss').onclick();
prompt(firstPage,'persisted',['question-1','question-2']);
assert.equal(firstPage.get('attention-dialog').shown,1,'同一问题关闭后轮询不再弹出');
const reloaded = page({storage});
prompt(reloaded,'persisted',['question-1','question-2']);
assert.equal(reloaded.get('attention-dialog').open,false,'刷新页面仍记住已关闭的问题');
prompt(reloaded,'persisted',['question-2']);
assert.equal(reloaded.get('attention-dialog').open,false,'已回答部分问题不会重新提醒其余已关闭问题');
prompt(reloaded,'persisted',['question-2','question-3']);
assert.equal(reloaded.get('attention-dialog').shown,1,'同一任务出现新问题仍提醒');
reloaded.get('attention-dialog').listeners.cancel();
prompt(reloaded,'persisted',['question-3']);
assert.equal(reloaded.get('attention-dialog').open,false,'Escape 与稍后处理共用去重');
prompt(reloaded,'another',['another-question']);
reloaded.get('attention-dismiss').onclick();
prompt(reloaded,'persisted',['question-1']);
assert.equal(reloaded.get('attention-dialog').open,false,'任务 A/B 轮换不会覆盖关闭记录');
prompt(reloaded,'another',['another-question']);
assert.equal(reloaded.get('attention-dialog').open,false,'多个已关闭任务分别去重');
reloaded.run('updateAttention(null); updateAttention(null,false)');
prompt(reloaded,'persisted',['question-1']);
assert.equal(reloaded.get('attention-dialog').open,false,'空快照与断线不清除真实问题记录');
reloaded.run("render({conversationsAvailable:false,conversations:[],quotaAvailable:false})");
prompt(reloaded,'persisted',['question-1']);
assert.equal(reloaded.get('attention-dialog').open,false,'采集暂不可用不清除已关闭的问题');

for (const corrupt of ['not json','{}','[null,{},7]']) {
  const corrupted = page({storage:new Map([['dismissed-attention-v1',corrupt]])});
  prompt(corrupted,'corrupt',['question']);
  assert.equal(corrupted.get('attention-dialog').open,true,'存储损坏不阻止新提醒');
  corrupted.get('attention-dismiss').onclick();
  prompt(corrupted,'corrupt',['question']);
  assert.equal(corrupted.get('attention-dialog').open,false,'存储损坏后仍可关闭提醒');
}
const noStorage = page({failAttentionStorage:true});
prompt(noStorage,'private',['question']);
noStorage.get('attention-dismiss').onclick();
prompt(noStorage,'private',['question']);
assert.equal(noStorage.get('attention-dialog').open,false,'存储不可用时本页仍可去重');

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
run("render({controlAllowed:true,conversationsAvailable:true,conversations:[{title:'双状态',threadId:'a',state:'running',unread:true}],quotaAvailable:false})");
const row = get('task-list').children[0];
assert.equal(row.className,'task running');
assert.ok(row.children.some(node => node.textContent === '正在进行'));
assert.ok(row.children.some(node => node.className === 'unread-mark' && node.textContent === '完成未读'));
assert.ok(row.children.findIndex(node => node.className === 'unread-mark') < row.children.findIndex(node => node.className === 'badge'));
assert.equal(row.children.at(-1).className,'badge');
run("render({controlAllowed:true,conversationsAvailable:true,conversations:[{title:'已读仍运行',threadId:'a',state:'running',unread:false}],quotaAvailable:false})");
assert.ok(!get('task-list').children[0].children.some(node => node.className === 'unread-mark'));

run("render({controlAllowed:true,conversationsAvailable:true,conversations:[{title:'计时',threadId:'a',state:'running',elapsedSeconds:125}],quotaAvailable:false})");
assert.equal(get('task-list').children[0].children.at(-2).textContent,'02:05');
assert.equal(get('task-list').children[0].children.at(-1).textContent,'正在进行');

// 验证连接成功、失败及恢复时颜色状态跟随真实刷新结果变化。
Object.assign(context, {AbortController, setTimeout, clearTimeout});
context.document.hidden = false;
(async () => {
  reloaded.context.document.hidden = false;
  reloaded.context.fetch = async () => {throw new Error('offline');};
  reloaded.run("token='test'");
  await reloaded.run('refresh()');
  prompt(reloaded,'persisted',['question-1']);
  assert.equal(reloaded.get('attention-dialog').open,false,'真实网络失败后恢复不重弹已关闭问题');

  // 新配对不能继承上一台 Mac 的关闭记录。
  const pairedAgain = page({storage});
  pairedAgain.context.fetch = async () => ({ok:true,json:async()=>({token:'new-pairing'})});
  pairedAgain.get('token').value = 'PAIRCODE';
  await pairedAgain.get('settings-form').listeners.submit({preventDefault(){}});
  assert.equal(pairedAgain.run('dismissedAttention.size'),0,'重新配对清除提醒关闭记录');
  prompt(pairedAgain,'persisted',['question-1']);
  assert.equal(pairedAgain.get('attention-dialog').open,true,'新配对收到同标识问题仍提醒');
  pairedAgain.get('attention-dismiss').onclick();
  pairedAgain.context.document.hidden = false;
  pairedAgain.context.document.querySelector = () => ({style:{}});
  pairedAgain.context.location = {reload(){}};
  pairedAgain.context.sessionStorage.removeItem = () => {};
  pairedAgain.context.fetch = async () => ({ok:false,status:401});
  await pairedAgain.run('refresh()');
  assert.equal(pairedAgain.run('dismissedAttention.size'),0,'配对失效清除内存提醒关闭记录');
  const retained = JSON.parse(storage.get('dismissed-attention-v1') || '[]');
  assert.equal(retained.length,0,'配对失效不保留上一会话的持久记录');

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
  run("render({controlAllowed:false,conversationsAvailable:true,conversations:[{title:'只读任务',threadId:'a',state:'running'}],quotaAvailable:false})");
  assert.equal(get('task-list').children[0].disabled,true,'只读会话不允许点击任务');
  assert.match(get('footer-note').textContent,/控制台尚未允许.*允许控制此 Mac/,'禁用任务时直接说明授权入口');
  let openedReadOnly=false;context.fetch=async()=>{openedReadOnly=true;throw Error('must not call');};
  await run("openConversation('a')");
  assert.equal(openedReadOnly,false);
  assert.match(get('footer-note').textContent,/控制台尚未允许.*允许控制此 Mac/);
  run("updateAttention({threadId:'read-only-attention',title:'只读待处理'})");
  assert.equal(get('attention-dialog').open,true,'只读会话继续显示待处理提醒');
  assert.equal(get('open-codex').disabled,true,'提醒保留展示但禁用控制');
  assert.match(get('open-result').textContent,/控制台尚未允许.*允许控制此 Mac/);
  await run("openConversation('read-only-attention')");
  assert.equal(get('open-result').textContent,get('footer-note').textContent,'已知只读时页脚和弹窗提示一致');
  // 服务端拒绝不能显示成网络故障；恢复授权后清除旧提示并可重新打开。
  run("render({controlAllowed:true,conversations:[],attention:{threadId:'denied',title:'权限测试'}})");
  context.fetch = async () => ({ok:false,status:403});
  await run("openConversation('denied')");
  assert.match(get('footer-note').textContent,/控制台尚未允许.*连接与配对/);
  assert.equal(get('open-result').textContent,get('footer-note').textContent);
  assert.equal(get('attention-dialog').open,true,'拒绝授权仍保留提醒');
  assert.equal(get('open-codex').disabled,true);
  run("render({controlAllowed:true,conversations:[],attention:{threadId:'denied',title:'权限测试'}})");
  assert.equal(get('footer-note').textContent,'','授权恢复后清除旧权限提示');
  assert.equal(get('open-result').textContent,'');
  assert.equal(get('open-codex').disabled,false);
  for (const status of [409,503,504]) {
    context.fetch = async () => ({ok:false,status});
    await run("openConversation('denied')");
    assert.match(get('footer-note').textContent,/未能确认打开/,'其他失败不能误报成未授权');
    assert.equal(get('open-result').textContent,get('footer-note').textContent);
  }
  // 慢请求的拒绝回执不能覆盖另一条新提醒。
  context.fetch = async () => {
    run("updateAttention({threadId:'new',title:'新提醒'})");
    get('open-result').textContent = '新提醒内容';
    return {ok:false,status:403};
  };
  await run("openConversation('denied')");
  assert.equal(get('open-result').textContent,'新提醒内容');
  run('controlAllowed=true');
  context.fetch = async () => ({ok:true,status:200,json:async()=>({ok:true})});
  await run("openConversation('new')");
  assert.equal(get('attention-dialog').open,false,'重新授权后仍可打开当前对话');
  // 打开旧问题的迟到成功回执，不能关闭同一对话刚出现的新问题。
  run("updateAttention({threadId:'late',title:'旧问题',requestIds:['old-question']})");
  let finishOpen;
  context.fetch = () => new Promise(resolve => { finishOpen = resolve; });
  const pendingOpen = run("openConversation('late')");
  run("updateAttention({threadId:'late',title:'新问题',requestIds:['new-question']})");
  finishOpen({ok:true,status:200,json:async()=>({ok:true})});
  await pendingOpen;
  assert.equal(get('attention-dialog').open,true,'旧问题打开成功不能关闭新问题');
  assert.equal(get('attention-title').textContent,'新问题');
  run("updateAttention({threadId:'late',title:'旧问题',requestIds:['old-question']})");
  assert.equal(get('attention-dialog').open,false,'打开成功只记忆请求发出时的问题');
  run("updateAttention({threadId:'late',title:'新问题',requestIds:['new-question']})");
  assert.equal(get('attention-dialog').open,true,'同一对话的新问题未被迟到回执忽略');
  run("updateAttention({threadId:'late-a',title:'任务 A',requestIds:['a-question']})");
  context.fetch = () => new Promise(resolve => { finishOpen = resolve; });
  const openingA = run("openConversation('late-a')");
  run("updateAttention({threadId:'late-b',title:'任务 B',requestIds:['b-question']})");
  finishOpen({ok:true,status:200,json:async()=>({ok:true})});
  await openingA;
  assert.equal(get('attention-dialog').open,true,'任务 A 的回执不关闭任务 B');
  assert.equal(get('attention-title').textContent,'任务 B');
  run("updateAttention({threadId:'late-a',title:'任务 A',requestIds:['a-question']})");
  assert.equal(get('attention-dialog').open,false,'切换任务后仍记住任务 A 已成功打开');

  // 旧会话在途回执不能影响重新配对后的提醒，也不能恢复已失效会话的记录。
  for (const boundary of ['token-change','invalidated']) {
    for (const status of [200,401]) {
      const stale = page();
      stale.run("token='old-session'");
      prompt(stale,'old-session-task',['old-session-question']);
      let finishStale;
      stale.context.fetch = () => new Promise(resolve => { finishStale = resolve; });
      const opening = stale.run("openConversation('old-session-task')");
      stale.run(boundary === 'token-change' ? "token='new-session'; clearAttentionDismissals()" : 'pairingInvalidated=true; clearAttentionDismissals()');
      prompt(stale,'new-session-task',['new-session-question']);
      stale.get('footer-note').textContent='新会话内容';
      stale.get('open-result').textContent='新提醒内容';
      finishStale({ok:status === 200,status,json:async()=>({ok:true})});
      await opening;
      assert.equal(stale.get('attention-dialog').open,true,`${boundary}/${status} 迟到回执不关闭新提醒`);
      assert.equal(stale.get('footer-note').textContent,'新会话内容');
      assert.equal(stale.get('open-result').textContent,'新提醒内容');
      assert.equal(stale.run('dismissedAttention.size'),0,`${boundary}/${status} 不写回旧会话记录`);
      if (boundary === 'token-change') {
        assert.equal(stale.run('token'),'new-session','旧 401 不能使新会话失效');
        assert.equal(stale.run('pairingInvalidated'),false);
      }
    }
  }
  for (const phase of ['response-body','network-error']) {
    const stale = page();
    stale.run("token='old-session'");
    prompt(stale,'old',['old-question']);
    let finishLate;
    stale.context.fetch = phase === 'response-body'
      ? async () => ({ok:true,status:200,json:() => new Promise(resolve => { finishLate = () => resolve({ok:true}); })})
      : () => new Promise((_,reject) => { finishLate = () => reject(new Error('offline')); });
    const opening = stale.run("openConversation('old')");
    await new Promise(setImmediate);
    stale.run("token='new-session'; clearAttentionDismissals()");
    prompt(stale,'new',['new-question']);
    stale.get('footer-note').textContent='新会话内容';
    finishLate();
    await opening;
    assert.equal(stale.get('attention-dialog').open,true,`${phase} 不关闭新会话提醒`);
    assert.equal(stale.get('footer-note').textContent,'新会话内容',`${phase} 不改写新会话内容`);
    assert.equal(stale.run('dismissedAttention.size'),0,`${phase} 不恢复旧关闭记录`);
  }
  // 被踢下线须立即隐藏旧页面并重载，清除各模块缓存；网络失败不走此路径。
  let reloads = 0;
  const pages = {style:{}};
  context.document.querySelector = selector => selector === '.pages' ? pages : null;
  context.location = {reload(){reloads++;}};
  run("render({controlAllowed:true,conversationsAvailable:true,conversations:[{title:'旧任务',threadId:'old',state:'running'}],quotaAvailable:false})");
  let removed;
  context.localStorage.removeItem = key => { removed = key; };
  let removedLegacy;
  context.sessionStorage.removeItem = key => { removedLegacy = key; };
  context.fetch = async () => ({ok:false,status:401});
  get('settings').close();
  get('console-confirm').showModal();
  get('console-confirm-name').textContent='旧项目名称';
  await run('refresh()');
  assert.equal(run('token'), '');
  assert.equal(removed, 'pairing-token');
  assert.equal(removedLegacy, 'display-token');
  assert.equal(pages.style.display, 'none', '失效后不能继续展示旧看板');
  assert.equal(reloads, 1, '重载销毁任务、音乐、额度和控制台的旧模块状态');
  assert.equal(get('console-confirm').open,false,'失效后立即关闭页面之外的确认框');
  assert.equal(get('console-confirm-name').textContent,'','重载前清除旧项目名称');
  assert.equal(get('task-list').children.length,0,'重载前清除历史任务');
  run("token = ''");
  await run('refresh()');
  assert.equal(get('connection').className,'disconnected');
  console.log('提醒关闭跨刷新、多个任务、新问题、断线、迟到回执、存储异常及配对清理验证通过');
})().catch(error => {console.error(error);process.exitCode=1;});

assert.equal(run('taskDuration(125)'), '02:05');
assert.equal(run('taskDuration(3601)'), '1:00:01');
assert.equal(run('taskDuration(undefined)'), '');
assert.equal(run('taskDuration(-1)'), '');
