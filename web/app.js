const breathStartedAt = Date.now();
const $ = id => document.getElementById(id);
const labels = {running:'正在进行', waiting:'等待你处理', done:'已完成', error:'需要关注', unknown:'暂无状态'};
// 套餐代码仅做显示规范化，不推断价格或权益；未知代码保留原值。
function formatPlan(plan) {
  const names = {promax:'Pro 500', pro:'Pro', plus:'Plus', free:'Free', team:'Team', business:'Business', enterprise:'Enterprise', edu:'Edu'};
  return typeof plan === 'string' && plan.trim() ? names[plan.toLowerCase()] || plan : '未知套餐';
}
let token = localStorage.getItem('pairing-token') || '';
// 未设置时默认开启；刷新后恢复用户选择，不把系统锁释放当成用户关闭。
const wakeUsesHTTPS = globalThis.location?.protocol === 'https:';
function supportsWakeLock() { return wakeUsesHTTPS && typeof navigator.wakeLock?.request === 'function'; }
function readWakePreference() {
  try { return localStorage.getItem('keep-awake-enabled') !== 'false'; } catch { return true; }
}
let busy = false, lastSuccess = 0, wakeLock = null, wantWake = supportsWakeLock() && readWakePreference();
let controlAllowed = false;
const controlRequiredMessage = '控制台尚未允许此网页控制 Mac，请在 Mac「iPad 控制台 → 连接与配对」中开启「允许控制此 Mac」。';
// 各页面共用同一授权指引；入口脚本先于其他页面模块执行。
globalThis.controlRequiredMessage = controlRequiredMessage;
let pairingInvalidated = false;
function invalidatePairing() {
  if (pairingInvalidated) return;
  pairingInvalidated = true; token = ''; controlAllowed = false;
  clearAttentionDismissals();
  localStorage.removeItem('pairing-token');
  // 旧版管理口令也必须清除，避免重载后继续携带失效凭据。
  sessionStorage.removeItem('display-token');
  // 先清除弹窗与敏感展示，再重载；慢网或重载失败也不能残留上一台 Mac 的内容。
  const pages = document.querySelector('.pages');
  if (pages) pages.style.display = 'none';
  for (const id of ['attention-dialog', 'console-confirm']) $(id)?.close();
  for (const id of ['task-list', 'windows', 'console-actions', 'relay-cards', 'lyric-track']) $(id)?.replaceChildren?.();
  for (const id of ['attention-title', 'open-result', 'footer-note', 'summary', 'task-count', 'plan', 'quota-note', 'list-note', 'console-confirm-name', 'console-confirm-target', 'console-confirm-description', 'console-status', 'relay-message', 'music-title', 'music-artist', 'music-source', 'music-control-result']) {
    if ($(id)) $(id).textContent = '';
  }
  updateAttention(null);
  if (typeof window !== 'undefined' && window.dispatchEvent) window.dispatchEvent(new Event('pairing-invalid'));
  location.reload();
}
globalThis.invalidatePairing = invalidatePairing;
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
  controlAllowed = data.controlAllowed === true;
  // 只读时说明授权入口；恢复后只清除此提示，保留其他操作结果。
  if (!controlAllowed) $('footer-note').textContent = controlRequiredMessage;
  else if ($('footer-note').textContent === controlRequiredMessage) $('footer-note').textContent = '';
  updateAttention(data.attention, data.conversationsAvailable === true);
  const {tasks, counts} = taskOverview(data);
  const total = data.conversationsTotal ?? tasks.length;
  $('task-count').textContent = data.conversationsAvailable ? (total > tasks.length ? `共 ${total} 个 · 显示 ${tasks.length} 个` : `${tasks.length} 个任务`) : '状态不可用';
  $('task-list').replaceChildren(...tasks.map(task => {
    const row = element('button', `task ${task.state in labels ? task.state : 'unknown'}`);
    // 【业务逻辑】上游列表仅保留完成后未读的对话；总体 done 不代表未读。
    row.type = 'button';
    row.disabled = !task.threadId || !controlAllowed;
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
  $('list-note').textContent = data.conversationsTotal > tasks.length ? `当前展示 ${tasks.length} 个任务，共 ${data.conversationsTotal} 个。` : '';
  $('plan').textContent = formatPlan(data.plan);
  $('open-codex').disabled = !controlAllowed;
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
async function refresh() {
  if (busy || document.hidden) return;
  if (!token) { $('connection').className = 'disconnected'; $('connection').textContent = '尚未连接'; $('settings').showModal(); return; }
  busy = true;
  const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 7000);
  try {
    const response = await fetch('./api/status',{headers:{'X-Pairing-Token':token},cache:'no-store',signal:controller.signal});
    if (response.status === 401) {
      invalidatePairing();
      return;
    }
    if (!response.ok) throw new Error('Mac 状态服务未连接');
    const data = await response.json();
    if (pairingInvalidated) return;
    if (!Number.isFinite(data.servedAt) || Date.now()/1000 - data.servedAt > 20) throw new Error('状态数据已过期');
    render(data); lastSuccess = Date.now(); $('connection').className = 'connected'; $('connection').textContent = '● 已连接';
  } catch (error) {
    // 移除总体状态栏后，连接错误仍需可见，避免把旧列表误认为实时数据。
    updateAttention(null, false);
    $('connection').className = 'disconnected';
    $('connection').textContent = error.name === 'AbortError' ? '连接超时，正在重试' : error.message;
    $('summary').textContent = lastSuccess ? '下方保留上次数据，并非当前状态' : '请检查 Mac 和网络连接';
  } finally { clearTimeout(timer); busy = false; }
}
const attentionDismissalKey = 'dismissed-attention-v1';
let attention = null, opening = false;
let dismissedAttention = new Set();
try {
  const stored = JSON.parse(localStorage.getItem(attentionDismissalKey) || '[]');
  if (Array.isArray(stored)) dismissedAttention = new Set(stored.filter(key => typeof key === 'string' && key.length <= 500).slice(-256));
} catch { }
function saveAttentionDismissals() {
  // 只保存问题标识，不保存标题和口令；限制记录数，浏览器禁用存储时仍可在本页去重。
  dismissedAttention = new Set(Array.from(dismissedAttention).slice(-256));
  try { localStorage.setItem(attentionDismissalKey, JSON.stringify(Array.from(dismissedAttention))); } catch { }
}
function clearAttentionDismissals() {
  dismissedAttention.clear();
  try { localStorage.removeItem(attentionDismissalKey); } catch { }
}
function attentionKeys(value) {
  const ids = Array.isArray(value.requestIds) ? value.requestIds.filter(id => typeof id === 'string' && id.length > 0 && id.length <= 200).slice(0, 64) : [];
  // 旧版 App 没有问题标识，只能按对话去重，确认已离开等待后再解除。
  return ids.length ? ids.map(id => JSON.stringify([value.threadId, id])) : [JSON.stringify([value.threadId])];
}
function rememberAttention(value) {
  if (!value) return;
  for (const key of attentionKeys(value)) dismissedAttention.add(key);
  saveAttentionDismissals();
}
function updateAttention(next, reset = true) {
  attention = next && typeof next.threadId === 'string' && typeof next.title === 'string' ? next : null;
  if (!attention) {
    if (reset) {
      // 无问题标识的兼容记录仅在确认不再等待时清除；断线与采集失败不能解除去重。
      let changed = false;
      for (const key of dismissedAttention) {
        try { if (JSON.parse(key).length === 1) changed = dismissedAttention.delete(key) || changed; } catch { changed = dismissedAttention.delete(key) || changed; }
      }
      if (changed) saveAttentionDismissals();
    }
    $('attention-dialog').close();
    return;
  }
  if (attentionKeys(attention).every(key => dismissedAttention.has(key))) {
    $('attention-dialog').close();
    return;
  }
  // 同一问题关闭后不再弹出，新问题使用独立标识，多个任务轮流出现也不会覆盖记录。
  $('attention-title').textContent = attention.title;
  $('open-codex').disabled = !controlAllowed;
  if (!controlAllowed) $('open-result').textContent = controlRequiredMessage;
  else if ($('open-result').textContent === controlRequiredMessage) $('open-result').textContent = '';
  if (!$('settings').open && !$('attention-dialog').open) {
    $('open-result').textContent = controlAllowed ? '' : controlRequiredMessage;
    $('attention-dialog').showModal();
  }
}
function dismissAttention() { rememberAttention(attention); $('attention-dialog').close(); }
$('attention-dismiss').onclick = dismissAttention;
$('attention-dialog').addEventListener('cancel', dismissAttention);
// 整张提醒都可打开对话；稍后处理和弹窗外遮罩不触发跳转。
$('attention-dialog').onclick = event => {
  if (!event.target.closest('.attention-card')) return;
  if (attention) return openConversation(attention.threadId);
};
async function openConversation(threadId) {
  if (!threadId || opening) return;
  if (!controlAllowed) {
    $('footer-note').textContent = controlRequiredMessage;
    if (attention?.threadId === threadId) $('open-result').textContent = controlRequiredMessage;
    return;
  }
  opening = true; $('open-codex').disabled = true;
  const requestedToken = token;
  const requestedAttention = attention?.threadId === threadId ? attention : null;
  $('open-result').textContent = '正在请求 Mac 打开对话…';
  $('footer-note').textContent = '正在请求 Mac 打开对话…';
  const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 18000);
  try {
    const response = await fetch('./api/open', {method:'POST', headers:{'Content-Type':'application/json','X-Pairing-Token':token}, body:JSON.stringify({threadId}), signal:controller.signal});
    if (pairingInvalidated || token !== requestedToken) return;
    if (response.status === 401) { invalidatePairing(); return; }
    if (response.status === 403) { controlAllowed = false; throw new Error('read-only'); }
    if (!response.ok || (await response.json()).ok !== true) throw new Error('open failed');
    if (pairingInvalidated || token !== requestedToken) return;
    // 状态可能已切换到另一对话，旧请求的回执不能关闭新提醒。
    $('footer-note').textContent = '';
    rememberAttention(requestedAttention);
    if (attention?.threadId === threadId) {
      // 打开请求期间若出现了新问题，不替用户关闭或忽略那个新问题。
      if (attentionKeys(attention).every(key => dismissedAttention.has(key))) $('attention-dialog').close();
    }
  } catch (error) {
    if (pairingInvalidated || token !== requestedToken) return;
    // 权限拒绝同时更新页脚与提醒，不能被网络错误覆盖；旧请求不改写新对话的提醒。
    const message = error.message === 'read-only' || !controlAllowed ? controlRequiredMessage : '未能确认打开：请检查 Mac 是否在线、任务是否仍在列表，然后重试';
    $('footer-note').textContent = message;
    if (attention?.threadId === threadId) $('open-result').textContent = message;
  } finally { clearTimeout(timeout); opening = false; $('open-codex').disabled = !controlAllowed; }
}
$('settings-form').addEventListener('submit', async event => {
  event.preventDefault(); $('pairing-error').textContent = '';
  try {
    const response = await fetch('./api/pairing/complete', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code:$('token').value.trim().toUpperCase()})});
    if (!response.ok) throw new Error('配对码无效或已过期，请查看 Mac App');
    const result = await response.json(); token = result.token;
    clearAttentionDismissals();
    localStorage.setItem('pairing-token', token); $('token').value = ''; $('settings').close();
    window.dispatchEvent(new Event('paired')); refresh();
  } catch (error) { $('pairing-error').textContent = error.message; }
});
$('cancel').onclick = () => $('settings').close();
const displayOptions = $('display-options');
function closeDisplayOptions() {
  displayOptions.hidden = true;
  $('more-settings').setAttribute('aria-expanded', 'false');
}
// iPadOS 15 没有 Popover API，菜单显式管理开关并同步辅助功能状态。
$('more-settings').onclick = () => {
  displayOptions.hidden = !displayOptions.hidden;
  $('more-settings').setAttribute('aria-expanded', String(!displayOptions.hidden));
};
// 在按钮处理前收起，异步操作及同步禁用按钮都不会把菜单留在屏幕上。
displayOptions.addEventListener('click', event => {
  if (event.target.closest('button')) closeDisplayOptions();
}, true);
document.addEventListener('pointerdown', event => {
  if (!displayOptions.hidden && !displayOptions.contains(event.target) && !$('more-settings').contains(event.target)) closeDisplayOptions();
}, true);
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && !displayOptions.hidden) {
    closeDisplayOptions();
    $('more-settings').focus();
  }
});
$('connect').onclick = () => $('settings').showModal();
$('refresh').onclick = refresh;
// 主屏幕独立模式没有地址栏，提供页面重载入口以获取最新界面。
$('reload').onclick = () => location.reload();
let wakePending = false, wakeFailed = false, wakeRestoring = wantWake;
const wakeInterrupted = '常亮已中断';
const wakeRestoreMessage = '设置已保留，浏览器尚未恢复常亮';
function saveWakePreference(enabled) {
  // 存储受限不能阻断当前开关操作，但必须告知下次可能无法恢复。
  try { localStorage.setItem('keep-awake-enabled', String(enabled)); }
  catch { $('footer-note').textContent = '无法保存常亮设置，本次操作仍会生效。'; }
}
function dismissWakeNotice() {
  $('wake-dialog').close();
}
function failWakeRequest(message) {
  // 本页申请失败后停止自动重试，已保存的选择留待重新加载时恢复。
  wantWake = false;
  wakeFailed = false;
  wakeRestoring = false;
  dismissWakeNotice();
  $('footer-note').textContent = message;
}
function notifyWakeInterrupted(message = wakeInterrupted) {
  if (!wantWake || document.hidden) return;
  $('wake-message').textContent = message;
  if (!$('wake-dialog').open) $('wake-dialog').showModal();
}
// 点击提供系统所需的用户手势，恢复申请失败时也退回关闭状态。
$('wake-dialog').onclick = async () => {
  if (!supportsWakeLock()) { showWakeState(); return; }
  if (wakePending) return;
  wakeFailed = false;
  wakeRestoring = false;
  wantWake = true;
  saveWakePreference(true);
  await keepAwake();
};
function showWakeState() {
  const supported = supportsWakeLock();
  // 不支持与暂时申请失败分开：前者禁用入口，后者仍允许手动重试。
  if (!supported) { wantWake = false; wakeFailed = false; wakeRestoring = false; dismissWakeNotice(); }
  // 高亮代表已持有有效锁，不代表用户曾请求开启。
  const active = supported && !!(wakeLock && !wakeLock.released);
  const unavailable = wantWake && !active && !wakePending;
  $('more-settings').setAttribute('data-wake-warning', String(unavailable));
  $('more-settings').setAttribute('aria-label', unavailable ? '更多设置，常亮未生效' : '更多设置');
  $('wake').textContent = !wakeUsesHTTPS ? '需 HTTPS 才能常亮' : !supported ? '浏览器不支持常亮' : active ? '常亮已开启' : wakePending ? '正在申请常亮…' : wakeFailed ? '点击恢复常亮' : '开启常亮';
  $('wake').setAttribute('aria-pressed', String(active));
  $('wake').disabled = !supported || wakePending;
  $('restore-wake').disabled = !supported || wakePending;
  $('wake-heading').textContent = !wakeUsesHTTPS ? '非 HTTPS 链接不支持常亮' : wakePending ? '正在恢复常亮…' : '点击任意位置恢复常亮';
}
async function keepAwake() {
  if (wakeLock?.released) wakeLock = null;
  if (!supportsWakeLock()) { showWakeState(); return; }
  if (!wantWake || document.hidden || wakeLock || wakePending || wakeFailed) return;
  wakePending = true;
  showWakeState();
  try {
    const lock = await navigator.wakeLock.request('screen');
    // 请求期间用户可能关闭常亮或切入后台，不能让迟到回执重新开启。
    if (!wantWake || document.hidden) { await lock.release(); return; }
    wakeLock = lock;
    wakeRestoring = false;
    dismissWakeNotice();
    if ($('footer-note').textContent.startsWith('常亮申请失败，')) $('footer-note').textContent = '';
    lock.addEventListener('release', () => {
      if (wakeLock === lock) wakeLock = null;
      if (wantWake && !document.hidden) wakeFailed = true;
      notifyWakeInterrupted();
      showWakeState();
    });
  } catch {
    // 自动恢复失败只暂停申请，保留开关选择，等待用户点击提供手势。
    if (wakeRestoring && wantWake) { wakeFailed = true; notifyWakeInterrupted(wakeRestoreMessage); }
    else failWakeRequest('常亮申请失败，已关闭。请检查低电量模式后重新开启。');
  } finally { wakePending = false; showWakeState(); }
}
$('wake').onclick = async () => {
  if (!supportsWakeLock()) { showWakeState(); return; }
  if (wakePending) return;
  wantWake = !(wakeLock && !wakeLock.released);
  wakeFailed = false;
  wakeRestoring = false;
  saveWakePreference(wantWake);
  if (wantWake) await keepAwake(); else await wakeLock?.release();
  if (!wantWake) dismissWakeNotice();
  showWakeState();
};
// 系统可在前台释放锁；限频重试，避免依赖用户触摸，也避免拒绝后忙循环。
setInterval(keepAwake, 5000);
// 本页仅恢复仍开启的常亮，手动关闭或申请失败后不会自动重开。
document.addEventListener('pointerup', event => { if (event.target.closest?.('#wake')) return; keepAwake(); });
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) {
    refresh();
    if (wakeRestoring && wakeFailed) notifyWakeInterrupted(wakeRestoreMessage);
    keepAwake();
  }
});
function showFullscreenState() {
  $('fullscreen').textContent = document.fullscreenElement ? '退出全屏' : navigator.standalone ? '已全屏显示' : '全屏显示';
}
$('fullscreen').onclick = async () => {
  try {
    // 浏览器全屏必须由用户点击触发，不能在页面加载时强制隐藏地址栏。
    if (document.fullscreenElement) await document.exitFullscreen();
    else if (navigator.standalone) return;
    else if (document.documentElement.requestFullscreen && document.fullscreenEnabled) await document.documentElement.requestFullscreen();
    else $('footer-note').textContent = '请在 Safari 点“分享 → 添加到主屏幕”，再从主屏图标打开，即可隐藏地址栏';
  } catch { $('footer-note').textContent = '未能进入全屏，请使用 Safari“分享 → 添加到主屏幕”后打开'; }
  showFullscreenState();
};
document.addEventListener('fullscreenchange', showFullscreenState);
showFullscreenState(); showWakeState(); keepAwake();
function clock() { $('clock').textContent = new Date().toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'}); }
clock(); setInterval(clock,1000); setInterval(() => {if(token) refresh();},1000); refresh();
