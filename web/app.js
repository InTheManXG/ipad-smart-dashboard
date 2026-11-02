const $ = id => document.getElementById(id);
const labels = {running:'正在进行', waiting:'等待你处理', done:'已完成', error:'需要关注', unknown:'暂无状态'};
let token = sessionStorage.getItem('display-token') || '';
let busy = false, lastSuccess = 0, wakeLock = null, wantWake = false;
function element(tag, className, text) {
  const node = document.createElement(tag); node.className = className;
  if (text !== undefined) node.textContent = text; // 对话标题始终当作文本，不能注入 HTML。
  return node;
}
function render(data) {
  updateAttention(data.attention);
  $('state').textContent = labels[data.state] || labels.unknown;
  $('signal').className = `signal ${data.state in labels ? data.state : 'unknown'}`;
  $('message').textContent = data.message || '暂无状态说明';
  const tasks = Array.isArray(data.conversations) ? data.conversations : [];
  $('task-count').textContent = data.conversationsAvailable ? `${data.conversationsTotal ?? tasks.length} 个任务` : '状态不可用';
  $('task-list').replaceChildren(...tasks.map(task => {
    const row = element('div', `task ${task.state in labels ? task.state : 'unknown'}`);
    // 【业务逻辑】上游列表仅保留完成后未读的对话；总体 done 不代表未读。
    row.append(element('span','dot'), element('div','task-title',task.title), element('span','badge',task.state === 'done' ? '完成未读' : labels[task.state] || '未知'));
    return row;
  }));
  if (!tasks.length) $('task-list').append(element('p','empty',data.conversationsAvailable ? '暂时没有活跃任务，新的工作会出现在这里。' : '暂时无法读取任务列表。'));
  const running = tasks.filter(t => t.state === 'running').length;
  const waiting = tasks.filter(t => t.state === 'waiting').length;
  $('summary').textContent = `当前列表：${running} 个进行中 · ${waiting} 个待处理`;
  $('list-note').textContent = data.conversationsTotal > tasks.length ? `展示最近 ${tasks.length} 个任务，共 ${data.conversationsTotal} 个。` : '与 Mac 上的 Codex 状态同步';
  $('plan').textContent = data.plan ? `Codex · ${data.plan}` : 'Codex';
  $('quota-note').textContent = !data.quotaAvailable ? '额度暂不可用' : data.cached ? '额度为上次缓存' : '额度约每分钟更新';
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
  if (!token) { $('connection').textContent = '尚未连接'; $('settings').showModal(); return; }
  busy = true;
  const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 7000);
  try {
    const response = await fetch('./api/status',{headers:{'X-Display-Token':token},cache:'no-store',signal:controller.signal});
    if (response.status === 401) throw new Error('口令无效，请重新连接');
    if (!response.ok) throw new Error('Mac 状态服务未连接');
    const data = await response.json();
    if (!Number.isFinite(data.servedAt) || Date.now()/1000 - data.servedAt > 20) throw new Error('状态数据已过期');
    render(data); lastSuccess = Date.now(); $('connection').textContent = '● 已连接';
    $('sync').textContent = `${new Date(lastSuccess).toLocaleTimeString('zh-CN')} 同步`;
  } catch (error) {
    updateAttention(null, false); $('connection').textContent = '● 连接中断'; $('state').textContent = '暂时离线'; $('signal').className = 'signal offline';
    $('message').textContent = error.name === 'AbortError' ? '连接超时，正在自动重试' : error.message;
    $('summary').textContent = lastSuccess ? '下方保留上次数据，并非当前状态' : '请检查 Mac 和网络连接';
  } finally { clearTimeout(timer); busy = false; }
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
    $('open-result').textContent = '点击后，在 Mac 上打开对应对话。';
    $('attention-dialog').showModal();
  }
}
function dismissAttention() { dismissedThread = attention?.threadId; $('attention-dialog').close(); }
$('attention-dismiss').onclick = dismissAttention;
$('attention-dialog').addEventListener('cancel', () => { dismissedThread = attention?.threadId; });
$('open-codex').onclick = async () => {
  if (!attention || opening) return;
  const threadId = attention.threadId;
  opening = true; $('open-codex').disabled = true;
  $('open-result').textContent = '正在请求 Mac 打开对话…';
  const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 18000);
  try {
    const response = await fetch('./api/open', {method:'POST', headers:{'Content-Type':'application/json','X-Display-Token':token}, body:JSON.stringify({threadId}), signal:controller.signal});
    if (!response.ok || (await response.json()).ok !== true) throw new Error('open failed');
    // 状态可能已切换到另一对话，旧请求的回执不能关闭新提醒。
    if (attention?.threadId === threadId) {
      dismissedThread = threadId; $('attention-dialog').close();
      $('footer-note').textContent = 'Mac 已接收打开请求，请查看 Codex 窗口';
    }
  } catch {
    if (attention?.threadId === threadId) $('open-result').textContent = '未能确认打开，请检查 Mac 是否在线或任务是否仍待处理，然后重试。';
  } finally { clearTimeout(timeout); opening = false; $('open-codex').disabled = false; }
};
$('settings-form').addEventListener('submit',event => {event.preventDefault(); token = $('token').value.trim(); sessionStorage.setItem('display-token',token); $('token').value = ''; $('settings').close(); refresh();});
$('cancel').onclick = () => $('settings').close();
$('connect').onclick = () => $('settings').showModal();
$('refresh').onclick = refresh;
async function keepAwake() {
  if (!('wakeLock' in navigator)) { $('footer-note').textContent = '当前连接不支持常亮，请在 iPad 设置中关闭自动锁定'; wantWake = false; return; }
  try { wakeLock = await navigator.wakeLock.request('screen'); $('wake').textContent = '已保持常亮'; wakeLock.addEventListener('release',() => {wakeLock = null; $('wake').textContent = '保持常亮';}); }
  catch { wantWake = false; $('footer-note').textContent = '未能保持常亮，请检查低电量模式或自动锁定设置'; }
}
$('wake').onclick = async () => {wantWake = !wantWake; if (wantWake) await keepAwake(); else {await wakeLock?.release();}};
document.addEventListener('visibilitychange',() => {if (!document.hidden) {refresh(); if (wantWake) keepAwake();}});
function clock() { $('clock').textContent = new Date().toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'}); }
clock(); setInterval(clock,1000); setInterval(() => {if(token) refresh();},2000); refresh();
