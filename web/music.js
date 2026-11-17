const musicNode = id => document.getElementById(id);
let musicSnapshot = null, musicReceived = 0, musicBusy = false;
let lyricKey = '', renderedSnapshot = null, lastLyricFrame = null;
let musicControlBusy = false, musicRevision = 0;
let musicControlAllowed = false;
let musicInvalidated = false;
const musicControlMessage = globalThis.controlRequiredMessage;

function lyricFrame(snapshot, elapsed) {
  if (!snapshot || elapsed > 8 || snapshot.state === 'offline') return {title:'等待音乐连接', artist:'Mac 上的音乐同步暂未连接', state:'未连接', current:'♪'};
  if (snapshot.state === 'idle') return {title:'等待音乐响起', artist:'在 Mac 上播放音乐，歌词会出现在这里', state:'未播放', current:'♪'};
  if (snapshot.state !== 'ready') return {title:'暂时无法读取音乐', artist:'正在尝试恢复播放信息', state:'连接异常', current:'♪'};
  const position = Math.min(snapshot.duration, snapshot.position + (snapshot.playing ? Math.max(0, elapsed) : 0));
  const frame = {title:snapshot.title, artist:snapshot.artist, source:snapshot.source, state:snapshot.playing ? '播放中' : '已暂停', position, duration:snapshot.duration};
  if (snapshot.lyricsState !== 'ready') return {...frame, current:{loading:'正在寻找歌词…', missing:'暂无匹配的时间轴歌词', error:'歌词获取失败，稍后重试'}[snapshot.lyricsState] || '暂无歌词'};
  const lines = snapshot.lines || [];
  // 每次按时间轴重新定位，拖动进度、切歌和恢复前台都不能沿用旧行号。
  let index = -1;
  for (let i = 0; i < lines.length && lines[i].time <= position; i++) index = i;
  return {...frame, index, previous:lines[index - 1]?.text || '', current:index < 0 ? '前奏' : lines[index]?.text || '间奏', next:lines[index + 1]?.text || ''};
}

function musicTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '--:--';
  const total = Math.floor(seconds), minutes = Math.floor(total / 60);
  return `${minutes}:${String(total % 60).padStart(2, '0')}`;
}

function renderLyrics(snapshot, frame) {
  const track = musicNode('lyric-track');
  const timed = Number.isInteger(frame.index);
  let key = lyricKey;
  if (snapshot !== renderedSnapshot || !timed) {
    key = timed ? JSON.stringify([snapshot.title, snapshot.artist, snapshot.source, snapshot.duration, snapshot.lines]) : frame.current;
  }
  const changed = key !== lyricKey;
  const active = timed ? frame.index + 1 : 0;
  if (changed) {
    const texts = timed ? ['前奏', ...snapshot.lines.map(line => line.text || '间奏')] : [frame.current];
    track.replaceChildren(...texts.map(text => {
      const node = document.createElement('p');
      node.className = 'lyric-line'; node.textContent = text;
      return node;
    }));
  }
  // 同一首歌自然前进时移动现有歌词；切歌、跳转和断线立即定位，避免扫过无关句子。
  const smooth = !changed && timed && lastLyricFrame &&
    frame.index >= lastLyricFrame.index && frame.index <= lastLyricFrame.index + 1 &&
    Math.abs(frame.position - lastLyricFrame.position) <= 2.5;
  track.className = smooth ? 'smooth' : '';
  if (changed || active !== (Number.isInteger(lastLyricFrame?.index) ? lastLyricFrame.index + 1 : 0)) {
    for (let i = 0; i < track.children.length; i++) track.children[i].className = i === active ? 'lyric-line active' : 'lyric-line';
  }
  track.style.transform = `translateY(calc(${1 - active} * var(--lyric-step)))`;
  lyricKey = key; renderedSnapshot = snapshot; lastLyricFrame = frame;
}

function renderMusic() {
  // 未配置或已停用时不占位；启用但暂时未播放仍保留音乐区域。
  const visible = !!musicSnapshot && (musicSnapshot.enabled === true || (musicSnapshot.enabled !== false && musicSnapshot.state !== 'offline'));
  musicNode('music-panel').hidden = !visible;
  musicNode('home').classList.toggle('music-hidden', !visible);
  const frame = lyricFrame(musicSnapshot, (performance.now() - musicReceived) / 1000);
  // 其他播放器及断线状态不显示网易云品牌图标。
  musicNode('music-source-logo').hidden = frame.source !== '网易云音乐';
  const values = {'music-title':frame.title, 'music-artist':frame.artist, 'music-source':frame.source || '音乐播放器',
    'music-elapsed':musicTime(frame.position), 'music-duration':musicTime(frame.duration)};
  for (const [id, value] of Object.entries(values)) {
    const node = musicNode(id);
    // 歌词来自外部服务，只写文本；不重复改写同一句，减少屏幕闪动。
    if (node.textContent !== value) node.textContent = value;
  }
  // 无歌词也显示真实播放进度；断线清零，不能继续推演旧歌曲的位置。
  musicNode('music-progress').max = frame.duration > 0 ? frame.duration : 1;
  musicNode('music-progress').value = Number.isFinite(frame.position) ? frame.position : 0;
  const available = musicControlAllowed && Number.isFinite(frame.position) && !!musicSnapshot?.trackId;
  for (const action of ['previous', 'replay', 'toggle', 'next']) musicNode(`music-${action}`).disabled = musicControlBusy || !available;
  const notice = musicNode('music-control-result');
  // 仅明确的只读响应显示授权指引；连接失败不能冒充用户未授权。
  if (musicSnapshot?.controlAllowed === false) {
    if (notice.textContent !== musicControlMessage) notice.textContent = musicControlMessage;
  } else if (notice.textContent === musicControlMessage) notice.textContent = '';
  const toggle = musicNode('music-toggle'), playing = musicSnapshot?.playing === true;
  if (toggle.dataset.playing !== String(playing)) {
    toggle.dataset.playing = String(playing);
    toggle.setAttribute('aria-label', playing ? '暂停' : '播放');
    toggle.title = playing ? '暂停' : '播放';
  }
  renderLyrics(musicSnapshot, frame);
}

async function controlMusic(action) {
  if (!musicControlAllowed) { musicNode('music-control-result').textContent = musicControlMessage; return; }
  if (musicControlBusy || !musicSnapshot?.trackId || (performance.now() - musicReceived) / 1000 > 8) return;
  const token = localStorage.getItem('pairing-token');
  if (!token) return;
  musicControlBusy = true;
  musicNode('music-control-result').textContent = '';
  renderMusic();
  const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch('./api/music/control', {method:'POST',headers:{'Content-Type':'application/json','X-Pairing-Token':token},
      body:JSON.stringify({action,trackId:musicSnapshot.trackId}),signal:controller.signal});
    if (response.status === 401) { globalThis.invalidatePairing?.(); return; }
    if (response.status === 403) {
      musicControlAllowed = false; musicRevision++;
      if (musicSnapshot) musicSnapshot.controlAllowed = false;
      throw new Error('read-only');
    }
    if (!response.ok) throw new Error('unconfirmed');
    const result = await response.json();
    if (musicInvalidated) return;
    if (result.ok !== true) throw new Error('unconfirmed');
    musicNode('music-control-result').textContent = '';
    if (result.snapshot) {
      // 回执已经包含真实状态；旧轮询晚到时不能把暂停按钮和进度改回去。
      musicRevision++;
      musicSnapshot = result.snapshot;
      musicReceived = performance.now();
    } else await refreshMusic();
  } catch (error) {
    // 超时不自动重试，避免上一曲/下一曲在回执丢失时执行两次。
    musicNode('music-control-result').textContent = error.message === 'read-only' || !musicControlAllowed ? musicControlMessage : '未能确认操作，请检查播放器后重试';
  } finally { clearTimeout(timeout); musicControlBusy = false; renderMusic(); }
}
for (const action of ['previous', 'replay', 'next']) musicNode(`music-${action}`).onclick = () => controlMusic(action);
musicNode('music-toggle').onclick = () => controlMusic(musicSnapshot?.playing ? 'pause' : 'play');

async function refreshMusic() {
  if (musicBusy || document.hidden) return;
  const token = localStorage.getItem('pairing-token');
  if (!token) { musicSnapshot = null; musicControlAllowed = false; renderMusic(); return; }
  musicBusy = true;
  const started = performance.now(), revision = musicRevision;
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 5000);
  try {
    const response = await fetch('./api/music', {headers:{'X-Pairing-Token':token}, cache:'no-store', signal:controller.signal});
    if (response.status === 401) { globalThis.invalidatePairing?.(); return; }
    if (!response.ok) throw new Error('music unavailable');
    const snapshot = await response.json();
    if (revision !== musicRevision) return;
    musicControlAllowed = snapshot.controlAllowed === true;
    musicSnapshot = snapshot;
    const received = performance.now();
    // 服务器进度在响应发出前计算；用半个往返耗时估计回程延迟，不依赖设备时钟一致。
    musicReceived = musicSnapshot.state === 'ready' && musicSnapshot.playing ? (started + received) / 2 : received;
  } catch {
    if (revision === musicRevision) musicSnapshot = null;
  } finally { clearTimeout(timer); musicBusy = false; renderMusic(); }
}

setInterval(refreshMusic, 1000);
function animateMusic() {
  // 按显示帧推进，避免 200ms 定时器把跨秒显示继续拖后；隐藏页面交给浏览器暂停。
  if (!document.hidden) renderMusic();
  requestAnimationFrame(animateMusic);
}
requestAnimationFrame(animateMusic);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshMusic(); });
refreshMusic();

if (typeof window !== 'undefined') window.addEventListener('paired', () => refreshMusic());
if (typeof window !== 'undefined') window.addEventListener('pairing-invalid', () => {
  musicInvalidated = true; musicRevision++; musicSnapshot = null; musicControlAllowed = false;
  renderMusic();
});
