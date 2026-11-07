const subscriptionStatus = document.getElementById('subscription-status');
const subscriptionList = document.getElementById('subscription-list');
const updateAll = document.getElementById('update-all-subscriptions');

function subscriptionToken() { return localStorage.getItem('pairing-token') || sessionStorage.getItem('display-token') || ''; }
function subscriptionHeaders() {
  const token = localStorage.getItem('pairing-token');
  return token ? {'X-Pairing-Token': token} : {'X-Display-Token': subscriptionToken()};
}
function subscriptionMessage(text, error = false) {
  subscriptionStatus.textContent = text;
  subscriptionStatus.className = error ? 'subscription-error' : 'subscription-ok';
}
function updateButtons(disabled) {
  updateAll.disabled = disabled;
  subscriptionList.querySelectorAll('button').forEach(button => { button.disabled = disabled; });
}
async function updateSubscription(id) {
  if (!subscriptionToken()) { subscriptionMessage('请先在首页连接看板', true); return; }
  updateButtons(true);
  subscriptionMessage(id ? '正在更新所选订阅…' : '正在更新全部订阅…');
  try {
    const response = await fetch('./api/subscriptions/update', {
      method: 'POST', headers: {'Content-Type': 'application/json', ...subscriptionHeaders()},
      body: JSON.stringify(id ? {id} : {})
    });
    if (!response.ok) throw new Error(response.status === 409 ? '已有订阅更新正在进行' : '订阅更新失败，请检查 Mac 连接');
    subscriptionMessage(id ? '所选订阅更新完成' : '全部订阅更新完成');
  } catch (error) {
    subscriptionMessage(error.message, true);
  } finally { updateButtons(false); }
}
async function loadSubscriptions() {
  if (!subscriptionToken()) { subscriptionList.replaceChildren(Object.assign(document.createElement('p'), {className:'empty', textContent:'请先在首页连接看板'})); return; }
  try {
    const response = await fetch('./api/subscriptions', {headers: subscriptionHeaders(), cache: 'no-store'});
    if (!response.ok) throw new Error('Mac 订阅脚本不可用');
    const items = await response.json();
    subscriptionList.replaceChildren(...items.map(item => {
      const row = document.createElement('div'); row.className = 'subscription-row';
      const label = document.createElement('div'); label.className = 'subscription-name';
      label.append(Object.assign(document.createElement('strong'), {textContent: item.remark}), Object.assign(document.createElement('span'), {textContent: item.id}));
      const button = document.createElement('button'); button.type = 'button'; button.textContent = '更新此订阅';
      button.onclick = () => updateSubscription(item.id); row.append(label, button); return row;
    }));
    if (!items.length) subscriptionList.append(Object.assign(document.createElement('p'), {className:'empty', textContent:'没有可更新的订阅'}));
  } catch (error) { subscriptionList.replaceChildren(Object.assign(document.createElement('p'), {className:'empty', textContent:error.message})); }
}
updateAll.onclick = () => updateSubscription(null);
window.addEventListener('hashchange', loadSubscriptions);
document.addEventListener('visibilitychange', () => { if (!document.hidden) loadSubscriptions(); });
loadSubscriptions();
