const breathStartedAt = Date.now();
const $ = id => document.getElementById(id);
const labels = {running:'正在进行', waiting:'等待你处理', done:'已完成', error:'需要关注', unknown:'暂无状态'};
// 套餐代码仅做显示规范化，不推断价格或权益；未知代码保留原值。
function formatPlan(plan) {
  const names = {promax:'Pro 500', pro:'Pro', plus:'Plus', free:'Free', team:'Team', business:'Business', enterprise:'Enterprise', edu:'Edu'};
  return typeof plan === 'string' && plan.trim() ? names[plan.toLowerCase()] || plan : '未知套餐';
}
let token = sessionStorage.getItem('display-token') || '';
let busy = false, lastSuccess = 0, wakeLock = null, wantWake = true;
let consoleData = null;
function element(tag, className, text) {
  const node = document.createElement(tag); node.className = className;
  if (text !== undefined) node.textContent = text; // 对话标题始终当作文本，不能注入 HTML。
  return node;
}
function taskOverview(data) {
  const tasks = Array.isArray(data.conversations) ? data.conversations : [];
  const counts = Object.fromEntries(['running','waiting','error','done'].map(state => [state, tasks.filter(t => t.state === state).length]));
  // 未读与运行可重叠，分类之和不代表去重后的对话总数。
  counts.done = tasks.filter(t => t.unread === true || t.state === 'done').length;
  const state = ['waiting','error','running','done'].find(state => counts[state]) || 'unknown';
  return {tasks, counts, state};
}
function taskDuration(seconds) {
  if (!Number.isInteger(seconds) || seconds < 0) return '';
  const h = Math.floor(seconds / 3600), m = Math.floor(seconds % 3600 / 60), sec = seconds % 60;
  return (h ? `${h}:` : '') + `${String(m).padStart(2,'0')}:${String(sec).padStart(2,'0')}`;
}
function render(data) {
  consoleData = data;
  updateAttention(data.attention);
  const {tasks, counts} = taskOverview(data);
  const total = data.conversationsTotal ?? tasks.length;
  $('task-count').textContent = data.conversationsAvailable ? (total > tasks.length ? `共 ${total} 个 · 显示 ${tasks.length} 个` : `${tasks.length} 个任务`) : '状态不可用';
  $('task-list').replaceChildren(...tasks.map(task => {
    const row = element('button', `task ${task.state in labels ? task.state : 'unknown'}`);
    // 【业务逻辑】上游列表仅保留完成后未读的对话；总体 done 不代表未读。
    row.type = 'button';
    row.disabled = !task.threadId;
    row.setAttribute('aria-label', `打开 Codex 对话：${task.title}`);
    // 【业务逻辑】仅使用上游真实 ID 打开对话，不能按同名标题猜测目标。
    row.onclick = () => openConversation(task.threadId);
    const dot = element('span','dot');
    // 轮询重建列表时沿用呼吸相位，避免每次刷新重新起亮。
    dot.style.animationDelay = `-${(Date.now() - breathStartedAt) % 1800}ms`;
    row.append(dot, element('div','task-title',task.title));
    // 未读标记排在当前状态左侧，让各行的运行状态保持右侧对齐。
    if (task.unread === true && task.state !== 'done') row.append(element('span','unread-mark','完成未读'));
    const duration = task.state === 'running' ? taskDuration(task.elapsedSeconds) : '';
    if (duration) {
      const timer = element('span','badge',duration);
      timer.setAttribute('aria-label', `本轮运行时长 ${duration}`);
      row.append(timer);
    }
    row.append(element('span','badge',task.state === 'done' ? '完成未读' : labels[task.state] || '未知'));
    return row;
  }));
  if (!tasks.length) $('task-list').append(element('p','empty',data.conversationsAvailable ? '暂时没有活跃任务，新的工作会出现在这里。' : '暂时无法读取任务列表。'));
  $('summary').textContent = data.conversationsAvailable ? `${counts.running} 个进行中 · ${counts.waiting} 个待处理 · ${counts.error} 个错误 · ${counts.done} 个完成未读` : '计数暂不可用';
  $('list-note').textContent = data.conversationsTotal > tasks.length ? `展示最近 ${tasks.length} 个任务，共 ${data.conversationsTotal} 个。` : '';
  $('plan').textContent = formatPlan(data.plan);
  $('quota-note').textContent = !data.quotaAvailable ? '额度暂不可用' : data.cached ? '额度为上次缓存' : '';
  $('windows').replaceChildren();
  for (const w of data.quotaAvailable ? [data.primary, data.secondary] : []) {
    if (!w || !Number.isFinite(w.usedPercent)) continue;
    const left = Math.max(0, Math.min(100, 100 - w.usedPercent));
    const box = element('div','window');
    const name = w.windowDurationMins === 10080 ? '每周额度' : w.windowDurationMins === 300 ? '5 小时额度' : '额度窗口';
    box.append(element('div','window-title',name));
    const value = element('div','window-value'); value.append(element('strong','',`${left}%`),element('span','','剩余'));
    const track = element('div','track'); const fill = element('div',left < 15 ? 'fill low' : 'fill');
    // 宽度只来自夹紧后的数字，避免服务数据成为任意样式。
    fill.style.width = `${left}%`; track.append(fill);
    const reset = Number.isFinite(w.resetsAt) ? new Date(w.resetsAt * 1000).toLocaleString('zh-CN',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'}) + ' 重置' : '重置时间未知';
    box.append(value, track, element('div','reset',reset)); $('windows').append(box);
  }
  if (!$('windows').children.length) $('windows').append(element('p','empty','当前没有可用的额度窗口'));
}
async function refresh(manual = false) {
  if (busy || document.hidden) return;
  if (!token) { $('connection').className = 'disconnected'; $('connection').textContent = '尚未连接'; $('settings').showModal(); renderConsole(false); return; }
  busy = true;
  // 自动轮询不反复改动按钮文字，手动刷新才显示操作反馈。
  if (manual) { $('console-refresh').disabled = true; $('console-refresh').textContent = '刷新中…'; }
  const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 7000);
  try {
    const response = await fetch('./api/status',{headers:{'X-Display-Token':token},cache:'no-store',signal:controller.signal});
    if (response.status === 401) throw new Error('口令无效，请重新连接');
    if (!response.ok) throw new Error('Mac 状态服务未连接');
    const data = await response.json();
    if (!Number.isFinite(data.servedAt) || Date.now()/1000 - data.servedAt > 20) throw new Error('状态数据已过期');
    render(data); lastSuccess = Date.now(); $('connection').className = 'connected'; $('connection').textContent = '● 已连接';
    renderConsole(true);
  } catch (error) {
    // 移除总体状态栏后，连接错误仍需可见，避免把旧列表误认为实时数据。
    updateAttention(null, false);
    $('connection').className = 'disconnected';
    $('connection').textContent = error.name === 'AbortError' ? '连接超时，正在重试' : error.message;
    $('summary').textContent = lastSuccess ? '下方保留上次数据，并非当前状态' : '请检查 Mac 和网络连接';
    renderConsole(false);
  } finally { clearTimeout(timer); busy = false; $('console-refresh').disabled = false; $('console-refresh').textContent = '刷新状态'; }
}
// 只聚合上游明确标记的等待和错误，不把完成未读当作必须处理。
function renderConsole(online) {
  const available = online && consoleData?.conversationsAvailable;
  const tasks = taskOverview(consoleData || {}).tasks.filter(task => ['waiting','error'].includes(task.state));
  $('console-connection').textContent = $('connection').textContent;
  $('console-connection').className = online ? 'connected' : 'disconnected';
  $('console-updated').textContent = lastSuccess ? `最近成功同步 ${new Date(lastSuccess).toLocaleTimeString('zh-CN')}` : '尚未收到数据';
  $('console-count').textContent = available ? `${tasks.length} 项` : '状态不可用';
  $('console-note').textContent = !online ? '连接不可用，保留的旧数据仅供参考' : !available ? '暂时无法读取任务列表' : consoleData.conversationsTotal > consoleData.conversations.length ? '仅汇总当前返回的任务；点击后在 Mac 打开对话' : '点击事项，在 Mac 打开对应对话';
  $('console-tasks').replaceChildren(...tasks.map(task => {
    const row = element('button', `task ${task.state}`);
    row.type = 'button'; row.disabled = !available || !task.threadId || opening;
    row.setAttribute('aria-label', `在 Mac 打开：${task.title}`);
    row.append(element('span','dot'), element('span','task-title',task.title), element('span','badge',labels[task.state]));
    row.onclick = () => openConversation(task.threadId);
    return row;
  }));
  if (!tasks.length) $('console-tasks').append(element('p','empty',available ? '暂无待处理事项' : '等待恢复连接或可用任务数据'));
}
function showOpenResult(message) {
  $('footer-note').textContent = message;
  $('console-result').textContent = message;
}
let attention = null, dismissedThread = null, opening = false;
function updateAttention(next, reset = true) {
  attention = next && typeof next.threadId === 'string' && typeof next.title === 'string' ? next : null;
  if (!attention) {
    if (reset) dismissedThread = null;
    $('attention-dialog').close();
    return;
  }
  // 【业务逻辑】同一待处理阶段只弹一次；解除后再次等待可重新提醒，连接失败不清除已忽略状态。
  $('attention-title').textContent = attention.title;
  if (attention.threadId !== dismissedThread && !$('settings').open && !$('attention-dialog').open) {
    $('open-result').textContent = '';
    $('attention-dialog').showModal();
  }
}
function dismissAttention() { dismissedThread = attention?.threadId; $('attention-dialog').close(); }
$('attention-dismiss').onclick = dismissAttention;
$('attention-dialog').addEventListener('cancel', () => { dismissedThread = attention?.threadId; });
// 整张提醒都可打开对话；稍后处理和弹窗外遮罩不触发跳转。
$('attention-dialog').onclick = event => {
  if (!event.target.closest('.attention-card')) return;
  if (attention) return openConversation(attention.threadId);
};
async function openConversation(threadId) {
  if (!threadId || opening) return;
  opening = true; $('open-codex').disabled = true;
  $('open-result').textContent = '正在请求 Mac 打开对话…';
  showOpenResult('正在请求 Mac 打开对话…');
  const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 18000);
  try {
    const response = await fetch('./api/open', {method:'POST', headers:{'Content-Type':'application/json','X-Display-Token':token}, body:JSON.stringify({threadId}), signal:controller.signal});
    if (!response.ok || (await response.json()).ok !== true) throw new Error('open failed');
    // 状态可能已切换到另一对话，旧请求的回执不能关闭新提醒。
    showOpenResult('已在 Mac 打开对话');
    if (attention?.threadId === threadId) {
      dismissedThread = threadId; $('attention-dialog').close();
    }
  } catch {
    showOpenResult('未能确认打开：请检查 Mac 是否在线、任务是否仍在列表，然后重试');
    if (attention?.threadId === threadId) $('open-result').textContent = '未能确认打开，请检查 Mac 是否在线或任务是否仍待处理，然后重试。';
  } finally { clearTimeout(timeout); opening = false; $('open-codex').disabled = false; }
}
$('settings-form').addEventListener('submit',event => {event.preventDefault(); token = $('token').value.trim(); sessionStorage.setItem('display-token',token); $('token').value = ''; $('settings').close(); refresh();});
$('cancel').onclick = () => $('settings').close();
$('connect').onclick = () => $('settings').showModal();
$('refresh').onclick = () => refresh(true);
// 主屏幕独立模式没有地址栏，提供页面重载入口以获取最新界面。
$('reload').onclick = () => location.reload();
let wakePending = false, wakeFailed = false;
const wakeInterrupted = '常亮已中断';
function dismissWakeNotice() {
  $('wake-dialog').close();
}
function notifyWakeInterrupted(message = wakeInterrupted) {
  if (!wantWake || document.hidden) return;
  $('wake-message').textContent = message;
  if (!$('wake-dialog').open) $('wake-dialog').showModal();
}
// 点击本身提供系统所需的用户手势，成功后再关闭，失败时留下可重试的提示。
$('wake-dialog').onclick = async () => {
  if (wakePending) return;
  wakeFailed = false;
  wantWake = true;
  await keepAwake();
};
function showWakeState() {
  // 高亮代表已持有有效锁，不代表用户曾请求开启。
  const active = !!(wakeLock && !wakeLock.released);
  const unavailable = wantWake && !active && !wakePending;
  $('more-settings').setAttribute('data-wake-warning', String(unavailable));
  $('more-settings').setAttribute('aria-label', unavailable ? '更多设置，常亮未生效' : '更多设置');
  $('wake').textContent = active ? '常亮已开启' : wakePending ? '正在申请常亮…' : wakeFailed ? '申请失败，点击重试' : '开启常亮';
  $('wake').setAttribute('aria-pressed', String(active));
  $('wake').disabled = wakePending;
  $('restore-wake').disabled = wakePending;
  $('console-wake').textContent = $('wake').textContent;
  $('console-wake').disabled = wakePending;
  $('console-wake').setAttribute('aria-pressed', String(active));
  $('wake-heading').textContent = wakePending ? '正在恢复常亮…' : '点击任意位置恢复常亮';
}
async function keepAwake() {
  if (wakeLock?.released) wakeLock = null;
  if (!wantWake || document.hidden || wakeLock || wakePending || wakeFailed) return;
  if (!('wakeLock' in navigator)) {
    wakeFailed = true;
    showWakeState();
    notifyWakeInterrupted('常亮申请失败：浏览器不支持，请在 iPad 设置中关闭自动锁定');
    return;
  }
  wakePending = true;
  showWakeState();
  try {
    const lock = await navigator.wakeLock.request('screen');
    // 请求期间用户可能关闭常亮或切入后台，不能让迟到回执重新开启。
    if (!wantWake || document.hidden) { await lock.release(); return; }
    wakeLock = lock;
    dismissWakeNotice();
    lock.addEventListener('release', () => {
      if (wakeLock === lock) wakeLock = null;
      if (wantWake && !document.hidden) wakeFailed = true;
      notifyWakeInterrupted();
      showWakeState();
    });
  } catch {
    wakeFailed = true;
    notifyWakeInterrupted('常亮申请失败，请再点一下重试；仍失败时请检查低电量模式。');
  } finally { wakePending = false; showWakeState(); }
}
$('wake').onclick = async () => {
  if (wakePending) return;
  wantWake = !(wakeLock && !wakeLock.released);
  wakeFailed = false;
  if (wantWake) await keepAwake(); else await wakeLock?.release();
  if (!wantWake) dismissWakeNotice();
  showWakeState();
};
// 系统可在前台释放锁；限频重试，避免依赖用户触摸，也避免拒绝后忙循环。
setInterval(keepAwake, 5000);
// 默认请求常亮；恢复前台或下一次用户操作时重试，避免后台重复申请。
document.addEventListener('pointerup', event => { if (event.target.closest?.('#wake, #console-wake')) return; keepAwake(); });
document.addEventListener('visibilitychange', () => { if (!document.hidden) { refresh(); keepAwake(); } });
function showFullscreenState() {
  $('fullscreen').textContent = document.fullscreenElement ? '退出全屏' : navigator.standalone ? '已全屏显示' : '全屏显示';
  $('console-fullscreen').textContent = $('fullscreen').textContent;
}
$('fullscreen').onclick = async () => {
  try {
    // 浏览器全屏必须由用户点击触发，不能在页面加载时强制隐藏地址栏。
    if (document.fullscreenElement) await document.exitFullscreen();
    else if (navigator.standalone) return;
    else if (document.documentElement.requestFullscreen && document.fullscreenEnabled) await document.documentElement.requestFullscreen();
    else showOpenResult('请在 Safari 点“分享 → 添加到主屏幕”，再从主屏图标打开，即可隐藏地址栏');
  } catch { showOpenResult('未能进入全屏，请使用 Safari“分享 → 添加到主屏幕”后打开'); }
  showFullscreenState();
};
document.addEventListener('fullscreenchange', showFullscreenState);
// 复用首页操作与权限边界，控制台不另建控制接口。
for (const action of ['refresh','connect','fullscreen','wake','reload']) {
  $('console-' + action).onclick = () => $(action).onclick();
}
showFullscreenState(); showWakeState(); keepAwake();
function clock() { $('clock').textContent = new Date().toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'}); }
clock(); setInterval(clock,1000); setInterval(() => {if(token) refresh();},1000); refresh();
