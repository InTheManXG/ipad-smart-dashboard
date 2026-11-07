const consoleList = document.getElementById('console-actions');
const consoleStatus = document.getElementById('console-status');
const consoleRefresh = document.getElementById('console-refresh');
let consoleSubmitting = false;
let consoleLoading = false;
let consoleRenderKey = '';
let consoleSelection = null;
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
  consoleList.replaceChildren(...items.map(item => {
    const card = document.createElement('div'); card.className = 'console-action';
    const header = document.createElement('div'); header.className = 'console-action-header';
    const name = document.createElement('strong'); name.textContent = item.name;
    const type = document.createElement('span'); type.className = 'console-action-type';
    type.textContent = item.kind === 'app' ? '应用' : item.kind === 'script' ? '脚本' : '命令';
    header.append(name, type);
    const state = document.createElement('p'); state.className = 'note';
    state.textContent = item.state === 'running' ? '正在执行…' : item.state === 'succeeded' ? (item.kind === 'app' ? '已打开' : '执行完成') : item.state === 'failed' ? '执行失败或超时，请检查 Mac 上的配置' : '就绪';
    if (item.state === 'failed') state.className = 'subscription-error';
    const button = document.createElement('button'); button.type = 'button';
    button.textContent = item.kind === 'app' ? '打开应用' : '执行'; button.disabled = busy;
    button.onclick = () => requestConsoleAction(item);
    card.append(header, state, button); return card;
  }));
  if (!items.length) consoleList.append(Object.assign(document.createElement('p'), {className: 'empty', textContent: '在 Mac App 的「快捷控制台」中添加应用或脚本'}));
}
async function loadConsole() {
  if (consoleLoading || consoleSubmitting) return;
  consoleLoading = true;
  try {
    const items = await consoleRequest('./api/console');
    renderConsole(items); consoleMessage('由配对的 Mac 执行');
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
setInterval(() => { if (!document.hidden && location.hash === '#console') loadConsole(); }, 3000);
loadConsole();
