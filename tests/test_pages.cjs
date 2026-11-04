// 首页位于中间：验证默认、直达、恢复和旋转时的定位，保留原生左右滑动。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const events = {}, scrollEvents = {};
const pages = {clientWidth:1024, scrollLeft:0, addEventListener(name, fn){scrollEvents[name]=fn;}};
const location = {hash:''};
vm.runInNewContext(fs.readFileSync('web/relay.js','utf8').split('// 三页导航共用现有入口，避免不同后端的静态资源白名单出现差异。')[1], {
  document:{querySelector(){return pages;}}, location,
  window:{addEventListener(name, fn){events[name]=fn;}}, requestAnimationFrame(fn){fn();}
});
assert.equal(pages.scrollLeft,1024);
for (const [hash, expected] of [['#console',0],['#company',2048],['#home',1024],['#unknown',1024]]) {
  location.hash=hash; events.hashchange(); assert.equal(pages.scrollLeft,expected);
  pages.scrollLeft=0; events.pageshow(); assert.equal(pages.scrollLeft,expected);
}
pages.scrollLeft=2048; scrollEvents.scroll(); pages.clientWidth=768; events.resize(); assert.equal(pages.scrollLeft,1536);
pages.scrollLeft=0; scrollEvents.scroll(); pages.clientWidth=1024; events.resize(); assert.equal(pages.scrollLeft,0);
console.log('三页默认、锚点直达、页面恢复和旋转定位验证通过');
