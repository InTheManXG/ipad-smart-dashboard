const $ = id => document.getElementById(id);
let keys = [], loading = false, editing = false, refreshPending = false;
function node(tag, className, text) {
  const value = document.createElement(tag);
  value.className = className;
  if (text !== undefined) value.textContent = text;
  return value;
}
async function api(path, body) {
  const token = sessionStorage.getItem('display-token') || '';
  if (!token) throw new Error('请先在工作看板中连接');
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 18000);
  try {
    const response = await fetch(`./api/relay/${path}`, {
      method:body ? 'POST' : 'GET', headers:{'X-Display-Token':token, ...(body ? {'Content-Type':'application/json'} : {})},
      body:body ? JSON.stringify(body) : undefined, signal:controller.signal, cache:'no-store'
    });
    if (!response.ok) throw new Error(response.status === 401 ? '访问口令无效，请重新连接' : '操作失败，请检查输入或稍后重试');
    return await response.json();
  } finally { clearTimeout(timer); }
}
function money(value, unit = 'USD') {
  return Number.isFinite(value) ? `${unit === 'USD' ? '$' : unit === 'CNY' ? '¥' : ''}${value.toLocaleString('zh-CN', {minimumFractionDigits:2, maximumFractionDigits:2})}` : '—';
}
function dailyRemaining(data) {
  // 进度条只使用订阅每日口径，缺失或无限额时不推算比例。
  if (!Number.isFinite(data.dailyLimit) || data.dailyLimit <= 0 || !Number.isFinite(data.dailyUsed)) return null;
  return Math.max(0, Math.min(100, (1 - data.dailyUsed / data.dailyLimit) * 100));
}
function renderUsage(card, item, data) {
  card.replaceChildren(node('h3','',item.name));
  if (data.error) { card.append(node('p','relay-error',data.error)); return; }
  const value = node('div','window-value');
  value.append(node('strong','relay-value',money(data.remaining, data.unit)), node('span','','剩余'));
  const left = dailyRemaining(data), track = node('div','track');
  if (left !== null) {
    const fill = node('div',left < 15 ? 'fill low' : 'fill');
    fill.style.width = `${left}%`; track.append(fill);
    track.setAttribute('role','meter'); track.setAttribute('aria-label','每日额度剩余比例');
    track.setAttribute('aria-valuemin','0'); track.setAttribute('aria-valuemax','100');
    track.setAttribute('aria-valuenow',String(left));
  } else {
    track.classList.add('unavailable'); track.setAttribute('aria-label','每日额度比例不可用');
  }
  card.append(value, track,
    node('div','reset relay-detail',`当日已用 ${money(data.dailyUsed)} / 每日额度 ${money(data.dailyLimit)}`),
    node('p','reset relay-time',`${new Date(data.updatedAt * 1000).toLocaleTimeString('zh-CN')} 更新`));
}
async function refreshRelay() {
  if (document.hidden || editing) return;
  if (loading) { refreshPending = true; return; }
  loading = true;
  try {
    keys = await api('keys');
    $('relay-message').textContent = keys.length ? '' : '尚未配置 Key';
    const cards = keys.map(item => {
      const card = node('article','relay-card');
      card.append(node('h3','',item.name), node('p','relay-caption','正在查询…'));
      return card;
    });
    $('relay-cards').replaceChildren(...cards);
    await Promise.all(keys.map(async (item, index) => {
      try { renderUsage(cards[index], item, await api(`usage?id=${encodeURIComponent(item.id)}`)); }
      catch { renderUsage(cards[index], item, {error:'查询失败，请稍后重试'}); }
    }));
  } catch (error) {
    // 认证或网络失败时移除旧额度，避免误认为仍是当前值。
    $('relay-cards').replaceChildren();
    $('relay-message').textContent = error.message;
  } finally {
    loading = false;
    if (refreshPending) { refreshPending = false; refreshRelay(); }
  }
}
function resetForm() {
  $('relay-form').reset(); $('relay-id').value = ''; $('relay-key').required = true;
  $('relay-form-message').textContent = '';
}
function renderKeyList() {
  $('relay-key-list').replaceChildren(...keys.map(item => {
    const row = node('div','relay-key-row'), edit = node('button','','编辑'), remove = node('button','','删除');
    edit.type = remove.type = 'button'; edit.disabled = remove.disabled = editing;
    edit.onclick = () => {
      resetForm(); $('relay-id').value = item.id; $('relay-name').value = item.name;
      $('relay-key').required = false; $('relay-name').focus();
    };
    remove.onclick = async () => {
      if (!confirm(`删除“${item.name}”的 Key 配置？`)) return;
      await mutate({action:'delete', id:item.id});
    };
    row.append(node('span','',item.name),edit,remove); return row;
  }));
}
async function mutate(body) {
  if (editing) return;
  editing = true; $('relay-save').disabled = true; renderKeyList();
  try {
    await api('keys', body);
    resetForm(); keys = await api('keys');
    $('relay-form-message').textContent = '已保存';
  } catch (error) { $('relay-form-message').textContent = error.message; }
  finally {
    editing = false; $('relay-save').disabled = false; renderKeyList();
    // 保存期间若仍有查询，完成后立即重读配置，避免旧卡片残留。
    refreshRelay();
  }
}
$('relay-manage').onclick = async () => {
  resetForm(); $('relay-settings').showModal();
  try { keys = await api('keys'); renderKeyList(); }
  catch (error) { $('relay-form-message').textContent = error.message; }
};
$('relay-form').addEventListener('submit', event => {
  event.preventDefault();
  mutate({action:'save', id:$('relay-id').value || undefined, name:$('relay-name').value.trim(), key:$('relay-key').value.trim()});
});
$('relay-new').onclick = resetForm;
$('relay-close').onclick = () => $('relay-settings').close();
$('relay-settings').addEventListener('close', () => { $('relay-key').value = ''; });
$('settings-form').addEventListener('submit', () => refreshRelay());
document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshRelay(); });
setInterval(refreshRelay, 60000);
refreshRelay();
// 刷新时浏览器可能恢复旧滚动位置，在页面恢复后重新应用直达锚点。
window.addEventListener('pageshow', () => {
  if (location.hash === '#company') requestAnimationFrame(() => $('company').scrollIntoView({block:'start', inline:'start'}));
});
