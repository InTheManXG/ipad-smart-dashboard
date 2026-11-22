// 联合加载页面模块，防止未配对控制台的 401 把配对页带入重载循环。
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

function page({storage = new Map(), session = new Map(), reject = false, permissions = {allowed:true}} = {}) {
  const nodes = new Map(), intervals = [], requests = [], listeners = new Map();
  const item = {id:'test-app', name:'测试应用', kind:'app', state:'idle'};
  let reloads = 0;
  function node(tag = '') {
    return {tag, children:[], style:{}, classList:{toggle(){}}, dataset:{}, open:false, textContent:'', value:'',
      listeners:new Map(), setAttribute(name, value){this[name] = value;},
      addEventListener(name, listener){this.listeners.set(name, listener);},
      showModal(){this.open = true;}, close(){this.open = false;}, focus(){},
      append(...children){this.children.push(...children);}, replaceChildren(...children){this.children = children;},
      querySelectorAll(tag){return this.children.flatMap(child => [...(child.tag === tag ? [child] : []), ...child.querySelectorAll(tag)]);}};
  }
  const get = id => { if (!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); };
  const pages = Object.assign(node(), {clientWidth:1024, scrollLeft:0});
  const context = vm.createContext({
    document:{hidden:false, getElementById:get, createElement:node, querySelector:() => pages, addEventListener(){}},
    window:{
      addEventListener(name, listener){if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(listener);},
      dispatchEvent(event){for (const listener of listeners.get(event.type) || []) listener(event);}
    },
    navigator:{}, location:{reload(){reloads++;}},
    localStorage:{getItem:key => storage.get(key) || null, setItem:(key, value) => storage.set(key, value), removeItem:key => storage.delete(key)},
    sessionStorage:{getItem:key => session.get(key) || null, removeItem:key => session.delete(key)},
    Event, Date, AbortController, setTimeout, clearTimeout, performance:{now(){return 0;}}, requestAnimationFrame(){},
    setInterval(callback){intervals.push(callback);},
    fetch:async (path, options) => {
      requests.push({path, options});
      if (path.endsWith('/pairing/complete')) return {ok:true, status:200, json:async () => ({token:'paired-token'})};
      const authenticated = Boolean(options.headers['X-Pairing-Token'] || options.headers['X-Display-Token']);
      if (!authenticated || reject) return {ok:false, status:401};
      const value = path.endsWith('/permissions') ? {controlAllowed:permissions.allowed} : path.endsWith('/console') ? [item] :
        path.endsWith('/music') ? {controlAllowed:permissions.allowed, enabled:true, state:'idle'} :
        {servedAt:Date.now() / 1000, controlAllowed:permissions.allowed, conversations:[], conversationsAvailable:true, quotaAvailable:false};
      return {ok:true, status:200, json:async () => value};
    }
  });
  // 各文件独立作用域对应浏览器 module，失效入口仍通过 globalThis 跨模块共享。
  for (const file of ['web/app.js', 'web/console.js', 'web/music.js']) {
    vm.runInContext(`(function () {\n${fs.readFileSync(file, 'utf8')}\n})()`, context, {filename:file});
  }
  assert.equal(vm.runInContext('typeof AbortSignal',context),'undefined','联合页面在没有 AbortSignal 静态 API 时正常加载');
  return {get, pages, storage, session, requests, intervals, permissions, reloads:() => reloads};
}
const settle = async () => { await new Promise(setImmediate); await new Promise(setImmediate); };

(async () => {
  const unpaired = page();
  await settle();
  for (const tick of unpaired.intervals) tick();
  await settle();
  assert.equal(unpaired.get('settings').open, true, '未配对时保持配对窗口');
  assert.equal(unpaired.requests.length, 0, '初次加载及轮询都不能发送无凭据请求');
  assert.equal(unpaired.reloads(), 0, '未配对页面不能自动重载');

  unpaired.get('token').value = 'ABCD2345';
  await unpaired.get('settings-form').listeners.get('submit')({preventDefault(){}});
  await settle();
  const consoleRequests = unpaired.requests.filter(request => request.path.endsWith('/console'));
  assert.equal(consoleRequests.length, 1, '完成配对后立即读取控制台，不等待下次轮询');
  assert.equal(consoleRequests[0].options.headers['X-Pairing-Token'], 'paired-token');
  assert.equal(unpaired.get('console-actions').children[0].children[1].children[0].children[1].textContent, '测试应用');
  assert.equal(unpaired.reloads(), 0, '正常配对不重载页面');

  const storage = new Map([['pairing-token', 'expired-token']]);
  const session = new Map([['display-token', 'legacy-token']]);
  const expired = page({storage, session, reject:true});
  await settle();
  assert.equal(expired.reloads(), 1, '已有令牌失效仍只执行一次重载');
  assert.equal(storage.has('pairing-token'), false, '401 清除失效令牌');
  assert.equal(session.has('display-token'), false, '401 同时清除旧管理凭据，防止重载后再次触发');
  assert.equal(expired.pages.style.display, 'none', '重载前隐藏旧看板');
  assert.equal(expired.get('task-list').children.length, 0);
  assert.equal(expired.get('console-actions').children.length, 0);
  const reloaded = page({storage, session, reject:true});
  await settle();
  for (const tick of reloaded.intervals) tick();
  await settle();
  assert.equal(reloaded.requests.length, 0, '失效重载后回到无请求的配对页');
  assert.equal(reloaded.reloads(), 0, '清除令牌后的页面不会继续重载');

  const legacy = page({session:new Map([['display-token', 'legacy-token']])});
  await settle();
  assert.equal(legacy.requests.filter(request => request.path.endsWith('/console')).length, 1, '旧管理凭据仍可读取控制台');
  assert.equal(legacy.requests[0].options.headers['X-Display-Token'], 'legacy-token');
  assert.equal(legacy.reloads(), 0);
  const readonly = page({storage:new Map([['pairing-token','readonly']]), permissions:{allowed:false}});
  await settle();
  const permissionMessage = readonly.get('footer-note').textContent;
  assert.match(permissionMessage,/控制台尚未允许.*允许控制此 Mac/);
  assert.equal(readonly.get('console-status').textContent,permissionMessage,'快捷操作与任务页共用授权文案');
  assert.equal(readonly.get('music-control-result').textContent,permissionMessage,'音乐与任务页共用授权文案');
  assert.equal(readonly.get('console-actions').querySelectorAll('button')[0].disabled,true);
  assert.equal(readonly.get('music-next').disabled,true);
  assert.equal(readonly.requests.filter(request=>request.options.method==='POST').length,0,'仅查看不会提交控制指令');
  readonly.permissions.allowed=true;
  for (const tick of readonly.intervals) tick();
  await settle();
  assert.equal(readonly.get('console-status').textContent,'');
  assert.equal(readonly.get('music-control-result').textContent,'');
  assert.equal(readonly.get('footer-note').textContent,'','恢复授权后三页旧提示均清除');
  const expiredSession = new Map([['display-token', 'expired-legacy-token']]);
  const expiredLegacy = page({session:expiredSession, reject:true});
  await settle();
  assert.equal(expiredLegacy.reloads(), 1, '只有旧管理凭据时也会正确处理 401');
  assert.equal(expiredSession.has('display-token'), false);
  const reloadedLegacy = page({session:expiredSession, reject:true});
  await settle();
  assert.equal(reloadedLegacy.requests.length, 0);
  assert.equal(reloadedLegacy.reloads(), 0, '旧管理凭据失效清除后不会继续重载');
  console.log('配对页联合模块：未配对无请求、即时配对、401 清理及旧凭据兼容通过');
})().catch(error => { console.error(error); process.exitCode = 1; });
