// 覆盖每日额度边界，避免把缺失、无限额或超额显示成错误比例。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const context = vm.createContext({document:{}});
vm.runInContext(fs.readFileSync('web/relay.js','utf8').split('async function refreshRelay(')[0],context);
for (const [data, expected] of [
  [{dailyLimit:300,dailyUsed:120},60],
  [{dailyLimit:300,dailyUsed:400},0],
  [{dailyLimit:300,dailyUsed:-10},100],
  [{dailyLimit:0,dailyUsed:0},null],
  [{dailyLimit:null,dailyUsed:0},null],
  [{dailyLimit:300,dailyUsed:null},null],
]) {
  context.data = data;
  assert.equal(vm.runInContext('dailyRemaining(data)',context),expected);
}
console.log('每日额度比例及缺失、超额边界验证通过');

// 模拟公网单指令通道，完整执行刷新流程，防止逐条 API 自检漏掉网页并发问题。
(async () => {
  const nodes = new Map();
  const makeNode = () => ({children:[],style:{},classList:{add(){}},append(...items){this.children.push(...items);},replaceChildren(...items){this.children=items;},setAttribute(){}});
  let active = 0, peak = 0, calls = [], failSecond = false;
  const fixture = [{id:'a',name:'一'},{id:'b',name:'二'},{id:'c',name:'三'},{id:'d',name:'四'}];
  const usage = {remaining:10,unit:'USD',updatedAt:1700000000,dailyLimit:20,dailyUsed:10};
  const page = vm.createContext({
    document:{hidden:false,createElement:makeNode,getElementById(id){if(!nodes.has(id))nodes.set(id,makeNode());return nodes.get(id);}},
    localStorage:{getItem(){return 'test-only';}},AbortController,setTimeout,clearTimeout,
    fetch:async url => {
      calls.push(url);
      if(url.endsWith('/keys'))return {ok:true,json:async()=>fixture};
      active++;peak=Math.max(peak,active);
      await new Promise(resolve=>setTimeout(resolve,5));
      const ok = active === 1 && !(failSecond && url.includes('id=b'));
      active--;
      return {ok,status:ok?200:409,json:async()=>url.includes('refresh=1')?usage:{}};
    },
  });
  vm.runInContext(fs.readFileSync('web/relay.js','utf8').split('// 手动更新绕过短期缓存')[0],page);
  await page.refreshRelay(true);
  assert.equal(peak,1,'四个 Key 的手动更新不能并发');
  assert.equal(calls.filter(url=>url.includes('refresh=1')).length,4);
  assert.equal(nodes.get('relay-cards').children.length,4);
  assert(nodes.get('relay-cards').children.every(card=>!card.children.some(child=>child.className==='relay-error')));
  calls=[];await page.refreshRelay(false);
  assert.equal(calls.filter(url=>url.includes('refresh=1')).length,4,'空快照自动请求实时额度');
  failSecond=true;await page.refreshRelay(true);
  assert.equal(nodes.get('relay-cards').children.filter(card=>card.children.some(child=>child.className==='relay-error')).length,1,'单个 Key 失败不影响其他 Key');
  assert.equal(nodes.get('relay-refresh').disabled,false,'刷新完成恢复按钮');
  console.log('四 Key 串行刷新、空快照回源及单 Key 失败隔离验证通过');
})().catch(error=>{console.error(error);process.exitCode=1;});
