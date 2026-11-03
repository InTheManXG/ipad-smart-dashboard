const musicNode = id => document.getElementById(id);
let musicSnapshot = null, musicReceived = 0, musicBusy = false;

function lyricFrame(snapshot, elapsed) {
  if (!snapshot || elapsed > 8 || snapshot.state === 'offline') return {title:'等待音乐连接', artist:'Mac 上的音乐同步暂未连接', state:'未连接', current:'♪'};
  if (snapshot.state === 'idle') return {title:'等待音乐响起', artist:'在 Mac 上播放音乐，歌词会出现在这里', state:'未播放', current:'♪'};
  if (snapshot.state !== 'ready') return {title:'暂时无法读取音乐', artist:'正在尝试恢复播放信息', state:'连接异常', current:'♪'};
  const position = Math.min(snapshot.duration, snapshot.position + (snapshot.playing ? Math.max(0, elapsed) : 0));
  const frame = {title:snapshot.title, artist:`${snapshot.artist} · ${snapshot.source}`, state:snapshot.playing ? '播放中' : '已暂停'};
  if (snapshot.lyricsState !== 'ready') return {...frame, current:{loading:'正在寻找歌词…', missing:'暂无匹配的时间轴歌词', error:'歌词获取失败，稍后重试'}[snapshot.lyricsState] || '暂无歌词'};
  const lines = snapshot.lines || [];
  // 每次按时间轴重新定位，拖动进度、切歌和恢复前台都不能沿用旧行号。
  let index = -1;
  for (let i = 0; i < lines.length && lines[i].time <= position; i++) index = i;
  return {...frame, previous:lines[index - 1]?.text || '', current:index < 0 ? '前奏' : lines[index]?.text || '间奏', next:lines[index + 1]?.text || ''};
}

function renderMusic() {
  const frame = lyricFrame(musicSnapshot, (performance.now() - musicReceived) / 1000);
  const values = {'music-title':frame.title, 'music-artist':frame.artist, 'music-state':frame.state,
    'lyric-previous':frame.previous || '', 'lyric-current':frame.current, 'lyric-next':frame.next || ''};
  for (const [id, value] of Object.entries(values)) {
    const node = musicNode(id);
    // 歌词来自外部服务，只写文本；不重复改写同一句，减少屏幕闪动。
    if (node.textContent !== value) node.textContent = value;
  }
}

async function refreshMusic() {
  if (musicBusy || document.hidden) return;
  const token = sessionStorage.getItem('display-token');
  if (!token) { musicSnapshot = null; renderMusic(); return; }
  musicBusy = true;
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 5000);
  try {
    const response = await fetch('./api/music', {headers:{'X-Display-Token':token}, cache:'no-store', signal:controller.signal});
    if (!response.ok) throw new Error('music unavailable');
    musicSnapshot = await response.json(); musicReceived = performance.now();
  } catch {
    musicSnapshot = null;
  } finally { clearTimeout(timer); musicBusy = false; renderMusic(); }
}

setInterval(refreshMusic, 1000);
setInterval(() => { if (!document.hidden) renderMusic(); }, 200);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshMusic(); });
refreshMusic();
