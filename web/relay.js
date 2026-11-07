const $ = id => document.getElementById(id);
let keys = [], loading = false, refreshPending = false;
function node(tag, className, text) {
  const value = document.createElement(tag);
  value.className = className;
  if (text !== undefined) value.textContent = text;
  return value;
}
async function api(path) {
  const token = localStorage.getItem('pairing-token') || '';
  if (!token) throw new Error('请先在工作看板中连接');
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 18000);
  try {
    const response = await fetch(`./api/relay/${path}`, {
      headers:{'X-Pairing-Token':token}, signal:controller.signal, cache:'no-store'
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
function keyHeading(item) {
  const heading = node('h3','');
  heading.append(node('span','',item.name));
  if (item.maskedKey) heading.append(node('span','relay-key-hint',item.maskedKey));
  return heading;
}
function renderUsage(card, item, data) {
  card.replaceChildren(keyHeading(item));
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
async function refreshRelay(force = false) {
  if (document.hidden) return;
  if (loading) { refreshPending = true; return; }
  loading = true;
  $('relay-refresh').disabled = true; $('relay-refresh').textContent = '更新中…';
  try {
    keys = await api('keys');
    $('relay-message').textContent = keys.length ? '' : '尚未配置 Key';
    const cards = keys.map(item => {
      const card = node('article','relay-card');
      card.append(keyHeading(item), node('p','relay-caption','正在查询…'));
      return card;
    });
    $('relay-cards').replaceChildren(...cards);
    // 同一 Mac 的配对指令只能串行执行，并发刷新会被服务端拒绝为 device_busy。
    for (const [index, item] of keys.entries()) {
      try {
        const path = `usage?id=${encodeURIComponent(item.id)}`;
        let data = await api(`${path}${force ? '&refresh=1' : ''}`);
        // 公网仅收到 Key 名单时可能尚无额度快照，不能把空对象画成查询成功。
        if (!force && !data.error && !Number.isFinite(data.updatedAt)) data = await api(`${path}&refresh=1`);
        renderUsage(cards[index], item, data.error || Number.isFinite(data.updatedAt) ? data : {error:'尚未收到额度，请稍后更新'});
      } catch { renderUsage(cards[index], item, {error:'查询失败，请稍后重试'}); }
    }
  } catch (error) {
    // 认证或网络失败时移除旧额度，避免误认为仍是当前值。
    $('relay-cards').replaceChildren();
    $('relay-message').textContent = error.message;
  } finally {
    loading = false;
    $('relay-refresh').disabled = false; $('relay-refresh').textContent = '更新';
    if (refreshPending) { refreshPending = false; refreshRelay(); }
  }
}
// 手动更新绕过短期缓存，自动轮询仍沿用一分钟缓存。
$('relay-refresh').onclick = () => refreshRelay(true);
window.addEventListener('paired', () => refreshRelay());
document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshRelay(); });
setInterval(refreshRelay, 60000);
refreshRelay();

// 三页导航共用现有入口，避免不同后端的静态资源白名单出现差异。
const pages = document.querySelector('.pages');
const pageIds = ['console', 'home', 'company'];
let currentPage = 1;
function showPage(id) {
  currentPage = Math.max(0, pageIds.indexOf(id));
  pages.scrollLeft = currentPage * pages.clientWidth;
}
function restorePage() {
  const id = location.hash.slice(1);
  showPage(pageIds.includes(id) ? id : 'home');
}
// 首页位于中间，加载和恢复页面时必须明确定位，不能默认露出左侧控制台。
restorePage();
window.addEventListener('pageshow', () => requestAnimationFrame(restorePage));
window.addEventListener('hashchange', restorePage);
pages.addEventListener('scroll', () => { currentPage = Math.round(pages.scrollLeft / pages.clientWidth); }, {passive:true});
// 旋转屏幕后按页定位，避免停留在两页之间。
window.addEventListener('resize', () => showPage(pageIds[currentPage] || 'home'));
