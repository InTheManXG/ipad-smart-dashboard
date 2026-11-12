const consoleList = document.getElementById('console-actions');
const consolePages = document.querySelector('.pages');
const consoleStatus = document.getElementById('console-status');
const consoleRefresh = document.getElementById('console-refresh');
let consoleSubmitting = false;
let consoleLoading = false;
let consoleRenderKey = '';
let consoleSelection = null;
const subscriptionFeedback = new Map();
const consoleConfirm = document.getElementById('console-confirm');

function consoleHeaders() {
  const token = localStorage.getItem('pairing-token');
  return token ? {'X-Pairing-Token': token} : {'X-Display-Token': sessionStorage.getItem('display-token') || ''};
}
function consoleMessage(message, error = false) {
  consoleStatus.textContent = message;
  consoleStatus.className = error ? 'subscription-error' : 'note';
}
async function consoleRequest(path, body) {
  const response = await fetch(path, {
    method: body ? 'POST' : 'GET', cache: 'no-store',
    headers: {...consoleHeaders(), ...(body ? {'Content-Type': 'application/json'} : {})},
    ...(body ? {body: JSON.stringify(body)} : {}), signal: AbortSignal.timeout(12000)
  });
  if (!response.ok) throw new Error(response.status === 401 ? '配对已失效，请在首页重新配对' : response.status === 409 ? '项目不可执行或已有任务运行，请刷新后重试' : response.status === 404 ? '项目已删除，请刷新列表' : 'Mac 未连接或控制台暂不可用');
  return response.json();
}
function renderConsole(items) {
  const busy = consoleSubmitting || items.some(item => item.state === 'running');
  // 轮询内容不变时保留按钮，避免触摸/键盘操作中节点被替换。
  const renderKey = JSON.stringify([items, busy]);
  if (renderKey === consoleRenderKey) return;
  consoleRenderKey = renderKey;
  const groups = [];
  for (const [kind, title] of [['app', '应用'], ['script', '脚本'], ['command', '命令'], ['subscription', '订阅更新']]) {
    const entries = items.filter(item => item.kind === kind);
    if (!entries.length) continue;
    const group = document.createElement('section'); group.className = kind === 'subscription' ? 'console-group console-group--subscriptions' : 'console-group';
    const heading = document.createElement('h3'); heading.textContent = title;
    const grid = document.createElement('div'); grid.className = 'console-group-grid';
    for (const item of entries) {
      if (kind === 'subscription') {
        const previous = subscriptionFeedback.get(item.id);
        if (!previous || previous.state !== item.state || previous.lastUpdatedAt !== item.lastUpdatedAt) {
          // 后台成功状态会常驻；只对新完成短暂反馈，轮询不续期，旧计时器不覆盖新任务。
          const feedback = {state:item.state, lastUpdatedAt:item.lastUpdatedAt, active:Boolean(previous) && item.state === 'succeeded'};
          subscriptionFeedback.set(item.id, feedback);
          if (feedback.active) setTimeout(() => {
            if (subscriptionFeedback.get(item.id) !== feedback) return;
            feedback.active = false; consoleRenderKey = ''; loadConsole();
          }, 3000);
        }
        // 只允许独立按钮触发更新，名称与行内空白不绑定操作，避免误触。
        const row = document.createElement('div'); row.className = 'console-subscription-row';
        const info = document.createElement('div'); info.className = 'console-subscription-info';
        const name = document.createElement('strong'); name.textContent = item.name;
        info.append(name);
        if (item.state === 'failed') {
          const state = document.createElement('span'); state.className = 'console-action-state';
          state.textContent = '更新失败'; state.className += ' console-action-state--failed';
          info.append(state);
        }
        const update = document.createElement('button'); update.type = 'button'; update.className = 'console-subscription-update';
        update.disabled = busy; update.textContent = item.state === 'running' ? '更新中…' : subscriptionFeedback.get(item.id).active ? '已更新' : '更新';
        update.setAttribute('aria-label', `${update.textContent}：${item.name}`);
        update.onclick = () => requestConsoleAction(item);
        const updated = document.createElement('span'); updated.className = 'console-subscription-updated';
        if (Number.isFinite(item.lastUpdatedAt) && item.lastUpdatedAt > 0 && item.lastUpdatedAt <= 253402300799) {
          const date = new Date(item.lastUpdatedAt * 1000);
          const time = document.createElement('time'); time.dateTime = date.toISOString();
          time.textContent = date.toLocaleString('zh-CN', {year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});
          updated.textContent = '上次更新'; updated.append(time);
        } else { updated.textContent = '暂无更新记录'; }
        row.append(info, update, updated); grid.append(row);
        continue;
      }
      const card = document.createElement('button'); card.type = 'button'; card.className = kind === 'app' ? 'console-action console-action--app' : 'console-action'; card.disabled = busy;
      const icon = document.createElement('span'); icon.className = 'console-icon';
      icon.textContent = kind === 'app' ? '▦' : kind === 'script' ? '≡' : '>_';
      if (kind === 'app' && /^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(item.icon || '')) {
        const image = document.createElement('img'); image.src = item.icon; image.alt = '';
        icon.replaceChildren(image);
      }
      const name = document.createElement('strong'); name.textContent = item.name;
      card.onclick = () => requestConsoleAction(item);
      card.append(icon, name);
      // 应用常态只显示图标和名称；处理中及失败仍提示，避免重复点击或误判结果。
      if (kind !== 'app' || item.state === 'running' || item.state === 'failed') {
        const state = document.createElement('span'); state.className = 'console-action-state';
        state.textContent = item.state === 'running' ? '正在执行…' : item.state === 'succeeded' ? '执行完成' : item.state === 'failed' ? '执行失败或超时' : '执行';
        card.append(state);
      }
      grid.append(card);
    }
    group.append(heading, grid); groups.push(group);
  }
  consoleList.replaceChildren(...groups);
  if (!items.length) consoleList.append(Object.assign(document.createElement('p'), {className: 'empty', textContent: '在 Mac App 的「快捷控制台」中添加应用或脚本'}));
}
async function loadConsole() {
  if (consoleLoading || consoleSubmitting) return;
  consoleLoading = true;
  try {
    const items = await consoleRequest('./api/console');
    renderConsole(items); consoleMessage('');
  } catch (error) {
    // 离线时禁止使用旧卡片触发操作，恢复连接后再读取最新配置。
    consoleRenderKey = ''; consoleList.replaceChildren(); consoleMessage(error.message, true);
  } finally { consoleLoading = false; }
}
function requestConsoleAction(item) {
  if (consoleSubmitting) return;
  if (item.kind === 'app') { runConsoleAction(item); return; }
  consoleSelection = item;
  document.getElementById('console-confirm-name').textContent = `在 Mac 上执行「${item.name}」？`;
  consoleConfirm.showModal();
}
async function runConsoleAction(item) {
  if (consoleSubmitting) return;
  consoleSubmitting = true; consoleRenderKey = '';
  consoleList.querySelectorAll('button').forEach(button => { button.disabled = true; });
  consoleMessage(`正在提交「${item.name}」…`);
  try {
    // 网页只发送 ID，不接受网页覆盖本机配置的命令、路径或解释器。
    await consoleRequest('./api/console/run', {id: item.id});
    consoleMessage('Mac 已接收，正在更新执行状态…');
    setTimeout(() => { consoleSubmitting = false; loadConsole(); }, 1200);
  } catch (error) {
    consoleSubmitting = false;
    consoleMessage(error.name === 'TimeoutError' ? '请求超时，执行结果未确认；请刷新状态，不要重复点击' : error.message, true);
    // 失败后由刷新恢复按钮；不自动重发可能已执行的任务。
  }
}
document.getElementById('console-confirm-run').onclick = () => {
  const item = consoleSelection; consoleSelection = null; consoleConfirm.close();
  if (item) runConsoleAction(item);
};
document.getElementById('console-confirm-cancel').onclick = () => { consoleSelection = null; consoleConfirm.close(); };
consoleConfirm.addEventListener('cancel', () => { consoleSelection = null; });
consoleRefresh.onclick = loadConsole;
window.addEventListener('hashchange', loadConsole);
document.addEventListener('visibilitychange', () => { if (!document.hidden) loadConsole(); });
// 手势切页不会更新 hash，轮询按实际滚动位置判断控制台是否可见。
setInterval(() => { if (!document.hidden && Math.round(consolePages.scrollLeft / consolePages.clientWidth) === 0) loadConsole(); }, 3000);
loadConsole();
