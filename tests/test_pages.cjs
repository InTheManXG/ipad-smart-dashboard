// 首页位于中间；独立音乐页的增减不能让用户正在查看的页面错位。
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const events = {}, scrollEvents = {};
const pages = {clientWidth:1024, scrollLeft:0, addEventListener(name, fn){scrollEvents[name]=fn;}};
const location = {hash:''};
const sections=Object.fromEntries(['console','home','music','company'].map(id=>[id,{hidden:id==='music'}]));
vm.runInNewContext(fs.readFileSync('web/relay.js','utf8').split('// 分页导航共用现有入口，布局变化时按页面 ID 保留位置。')[1], {
  document:{querySelector(){return pages;},getElementById(id){return sections[id];}}, location,
  window:{addEventListener(name, fn){events[name]=fn;}}, requestAnimationFrame(fn){fn();}
});
assert.equal(pages.scrollLeft,1024);
for (const [hash, expected] of [['#console',0],['#company',2048],['#home',1024],['#unknown',1024]]) {
  location.hash=hash; events.hashchange(); assert.equal(pages.scrollLeft,expected);
  pages.scrollLeft=0; events.pageshow(); assert.equal(pages.scrollLeft,expected);
}
pages.scrollLeft=2048; scrollEvents.scroll(); pages.clientWidth=768; events.resize(); assert.equal(pages.scrollLeft,1536);
pages.scrollLeft=0; scrollEvents.scroll(); pages.clientWidth=1024; events.resize(); assert.equal(pages.scrollLeft,0);
location.hash='#company';events.hashchange();
sections.music.hidden=false;events['page-layout-change']();
assert.equal(pages.scrollLeft,3072,'新增音乐页时仍停在Key页');
location.hash='#music';events.hashchange();assert.equal(pages.scrollLeft,2048);
pages.clientWidth=768;events.resize();assert.equal(pages.scrollLeft,1536,'旋转后保留音乐页');
sections.music.hidden=true;events['page-layout-change']();assert.equal(pages.scrollLeft,768,'隐藏当前音乐页后回到任务页');
location.hash='#company';events.hashchange();assert.equal(pages.scrollLeft,1536,'Key页恢复到第三页');
sections.music.hidden=false;events['page-layout-change']();assert.equal(pages.scrollLeft,2304);
pages.scrollLeft=0;scrollEvents.scroll();sections.music.hidden=true;events['page-layout-change']();assert.equal(pages.scrollLeft,0,'控制台位置保持不变');
location.hash='#music';events.pageshow();assert.equal(pages.scrollLeft,768);
scrollEvents.scroll();sections.music.hidden=false;events['page-layout-change']();assert.equal(pages.scrollLeft,1536,'刷新时等待布局快照后恢复音乐页');
sections.music.hidden=true;events.pageshow();pages.scrollLeft=0;scrollEvents.scroll();
sections.music.hidden=false;events['page-layout-change']();assert.equal(pages.scrollLeft,0,'用户主动滑离后不被迟到快照拉回');
console.log('默认、锚点、页面增减、恢复和旋转定位验证通过');
