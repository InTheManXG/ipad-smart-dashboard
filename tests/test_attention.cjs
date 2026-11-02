// 用轻量 DOM 替身验证提醒去重与状态切换，不触发真实 Mac 跳转。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const nodes = new Map();
const get = id => {
  if (!nodes.has(id)) nodes.set(id, {setAttribute(){},open:false, textContent:'', addEventListener(){}, showModal(){this.open=true; this.shown=(this.shown||0)+1;}, close(){this.open=false;}});
  return nodes.get(id);
};
const context = vm.createContext({document:{getElementById:get,hidden:true,addEventListener(){}}, navigator:{},sessionStorage:{getItem(){return '';}}, setInterval(){}, Date});
vm.runInContext(fs.readFileSync('web/app.js','utf8'), context);
const run = code => vm.runInContext(code, context);
run('updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,1);
run('dismissAttention(); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').open,false);
run('updateAttention(null,false); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,1);
run('updateAttention(null); updateAttention({threadId:"a",title:"任务 A"})');
assert.equal(get('attention-dialog').shown,2);
run('updateAttention(null,false)');
assert.equal(get('attention-dialog').open,false);
console.log('提醒首次弹出、关闭去重、断线和再次等待验证通过');
