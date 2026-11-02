// 覆盖每日额度边界，避免把缺失、无限额或超额显示成错误比例。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const context = vm.createContext({document:{}});
vm.runInContext(fs.readFileSync('web/relay.js','utf8').split('async function refreshRelay()')[0],context);
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
