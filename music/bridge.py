"""读取 Mac 系统当前播放，匹配网易云时间轴歌词，上报到已认证的看板。"""
import argparse
import hashlib
import http.client
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import re
import subprocess
import time
import threading
import unicodedata
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
MEDIA_CONTROL = '/opt/homebrew/bin/media-control'
_connections = {}
_connection_locks = defaultdict(threading.Lock)
CONTROL_ARGS = {'previous': ['previous-track'], 'next': ['next-track'], 'play': ['play'],
                'pause': ['pause'], 'replay': ['seek', '0']}


def fetch(path, params):
    request = Request('https://music.163.com/api/' + path + '?' + urlencode(params),
                      headers={'User-Agent': 'Mozilla/5.0', 'Referer': 'https://music.163.com/'})
    with urlopen(request, timeout=6) as response:
        raw = response.read(2_000_001)
    if len(raw) > 2_000_000:
        raise ValueError('lyrics response too large')
    result = json.loads(raw)
    if not isinstance(result, dict) or result.get('code') != 200:
        raise ValueError('lyrics service unavailable')
    return result


def normalize(text):
    return re.sub(r'[\W_]+', '', unicodedata.normalize('NFKC', text).casefold())


def parse_lrc(text):
    offset = re.search(r'\[offset:([+-]?\d+)\]', text, re.I)
    offset = int(offset[1]) / 1000 if offset else 0
    grouped = {}
    for raw in text.splitlines():
        tags = re.findall(r'\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]', raw)
        if not tags:
            continue
        content = re.sub(r'\[[^\]]*\]', '', raw).strip()[:300]
        for minute, second, fraction in tags:
            # LRC 正偏移代表歌词提前；空白行保留，用于清除间奏中的上一句。
            stamp = max(0, int(minute) * 60 + int(second) + float('0.' + (fraction or '0')) - offset)
            if stamp <= 86400:
                grouped.setdefault(stamp, [])
                if content and content not in grouped[stamp]:
                    grouped[stamp].append(content)
    return [{'time': stamp, 'text': ' / '.join(grouped[stamp])[:300]} for stamp in sorted(grouped)][:1000]


def find_lyrics(track):
    # shortcut: 搜索漏收的旧版用已核对链接补齐；积累更多漏收歌曲时再接入可靠的歌曲 ID 来源。
    if (normalize(track['title']) == normalize('梦醒时分') and
            normalize(track['artist']) == normalize('周冰倩') and
            normalize(track.get('album', '')) == normalize('梦醒时分') and
            abs(track['duration'] - 244.333) <= 1):
        data = fetch('song/lyric', {'id': 334909, 'lv': -1, 'kv': -1, 'tv': -1})
        lines = parse_lrc(data.get('lrc', {}).get('lyric', ''))
        if lines:
            return lines
    songs = fetch('search/get', {'s': track['title'] + ' ' + track['artist'], 'type': 1, 'limit': 30}).get('result', {}).get('songs', [])
    title, artist = normalize(track['title']), normalize(track['artist'])
    candidates = []
    for song in songs:
        artists = [normalize(a.get('name', '')) for a in song.get('artists', [])]
        difference = abs(song.get('duration', 0) / 1000 - track['duration'])
        # 不将同名翻唱或相近标题当原曲；时长差过大也不能同步同一份时间轴。
        if (normalize(song.get('name', '')) == title and artist and
                (artist in artists or artist == ''.join(artists)) and difference <= 4):
            album_matches = normalize(song.get('album', {}).get('name', '')) == normalize(track.get('album', ''))
            candidates.append((not album_matches, difference, song['id']))
    if not candidates:
        return []
    song_id = min(candidates)[2]
    data = fetch('song/lyric', {'id': song_id, 'lv': -1, 'kv': -1, 'tv': -1})
    return parse_lrc(data.get('lrc', {}).get('lyric', ''))


def read_player():
    raw = subprocess.check_output([MEDIA_CONTROL, 'get', '--no-artwork', '--now'], timeout=4)
    player = json.loads(raw)
    if not player:
        return {'state': 'idle'}
    if not isinstance(player, dict):
        raise ValueError('invalid player metadata')
    # 不把浏览器视频或系统提示音误作歌曲；其余音乐播放器沿用系统元数据。
    bundle = player.get('bundleIdentifier', '')
    names = {'com.netease.163music': '网易云音乐', 'com.apple.Music': 'Apple Music',
             'com.spotify.client': 'Spotify', 'com.tencent.QQMusicMac': 'QQ 音乐'}
    if bundle not in names:
        return {'state': 'idle'}
    duration = player.get('duration')
    position = player.get('elapsedTimeNow', player.get('elapsedTime'))
    if not isinstance(duration, (int, float)) or not isinstance(position, (int, float)):
        return {'state': 'unavailable'}
    # 网易云在 seek 后会更换临时内容 ID；使用歌曲元信息摘要，避免把本曲重播误判为切歌。
    identity = [bundle, player.get('title'), player.get('artist'), player.get('album'), duration]
    return {'state': 'ready', 'title': str(player.get('title', ''))[:300],
            'trackId': hashlib.sha256(json.dumps(identity, ensure_ascii=False).encode()).hexdigest(),
            'artist': str(player.get('artist', ''))[:300], 'album': str(player.get('album', ''))[:300], 'source': names[bundle],
            'playing': player.get('playing') is True, 'duration': max(0, min(duration, 86400)),
            'position': max(0, min(position, duration)), 'lyricsState': 'loading', 'lines': []}


def send(url, token, value):
    target = urlsplit(url)
    origin = (target.scheme, target.netloc)
    # 上报和回执复用 TLS 连接；各站点独立加锁，连接断开后交给下轮重连，不重试本次操作。
    with _connection_locks[origin]:
        connection = _connections.get(origin)
        if connection is None:
            factory = http.client.HTTPSConnection if target.scheme == 'https' else http.client.HTTPConnection
            connection = _connections[origin] = factory(target.hostname, target.port, timeout=4)
        try:
            connection.request('POST', target.path or '/', body=json.dumps(value, ensure_ascii=False).encode(),
                               headers={'X-Display-Token': token, 'Content-Type': 'application/json'})
            with connection.getresponse() as response:
                raw = response.read()
                if response.status != 200:
                    raise OSError('music upload failed')
                return json.loads(raw)
        except (OSError, ValueError, http.client.HTTPException) as error:
            _connections.pop(origin, None)
            connection.close()
            raise OSError('music connection failed') from error


def publish(url, token, snapshot):
    started = time.monotonic()
    data = send(url + '/api/music', token, snapshot)
    return data.get('command'), started


def execute_control(command, started):
    if (not isinstance(command, dict) or command.get('action') not in CONTROL_ARGS or
            not isinstance(command.get('trackId'), str) or type(command.get('expiresIn')) not in (int, float) or
            not 0 < command['expiresIn'] <= 8):
        return False
    deadline = started + command['expiresIn']
    before = read_player()
    if before.get('trackId') != command['trackId'] or time.monotonic() >= deadline:
        return False
    action = command['action']
    # 只执行固定参数，不把网页输入作为命令；播放/暂停使用确定状态，避免重复切换。
    subprocess.run([MEDIA_CONTROL, *CONTROL_ARGS[action]], check=True, timeout=2, capture_output=True)
    if action == 'replay':
        if read_player().get('trackId') != command['trackId'] or time.monotonic() >= deadline:
            return False
        subprocess.run([MEDIA_CONTROL, 'play'], check=True, timeout=2, capture_output=True)
    until = min(deadline, time.monotonic() + 2)
    while time.monotonic() < until:
        current = read_player()
        same = current.get('trackId') == command['trackId']
        if current.get('state') == 'ready':
            if action in ('next', 'previous') and not same:
                return current
            if same and ((action == 'play' and current['playing']) or
                         (action == 'pause' and not current['playing']) or
                         (action == 'replay' and current['playing'] and current['position'] < 3)):
                return current
        time.sleep(.1)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', action='append', required=True)
    parser.add_argument('--token-file', type=Path, default=ROOT / '.display-token')
    args = parser.parse_args()
    # 只允许 HTTPS 或本机回环地址传递口令，不把口令放到命令参数中。
    for url in args.url:
        if not (url.startswith('https://') or url.startswith('http://127.0.0.1:')):
            parser.error('音乐上报仅支持 HTTPS 或本机回环地址')
    token = args.token_file.read_text().strip()
    cache, pending, completed = {}, None, {}
    with ThreadPoolExecutor(max_workers=1) as lyrics_pool, ThreadPoolExecutor(max_workers=len(args.url)) as uploads:
        while True:
            started = time.monotonic()
            try:
                snapshot = read_player()
            except (OSError, ValueError, subprocess.SubprocessError):
                snapshot = {'state': 'unavailable'}
            if pending and pending[1].done():
                key, future = pending
                try:
                    lines = future.result()
                    cache[key] = (time.monotonic(), 'ready' if lines else 'missing', lines)
                except (OSError, ValueError, TypeError, KeyError, AttributeError):
                    cache[key] = (time.monotonic(), 'error', [])
                pending = None
                if len(cache) > 32:
                    del cache[next(iter(cache))]
            if snapshot['state'] == 'ready':
                key = (snapshot['title'], snapshot['artist'], snapshot['album'], round(snapshot['duration']))
                cached = cache.get(key)
                if cached:
                    snapshot['lyricsState'], snapshot['lines'] = cached[1:]
                if pending is None and (not cached or (cached[1] == 'error' and time.monotonic() - cached[0] >= 60)):
                    pending = (key, lyrics_pool.submit(find_lyrics, dict(snapshot)))
            # 两个站点独立请求；本机不可达不妨碍线上同步，失败不会终止采集循环。
            futures = {uploads.submit(publish, url.rstrip('/'), token, snapshot): url for url in args.url}
            for future in as_completed(futures):
                url = futures[future]
                try:
                    command, sent_at = future.result()
                    if not isinstance(command, dict) or not isinstance(command.get('requestId'), str):
                        continue
                    request_id = command['requestId']
                    # 回执丢失时只补发当前状态，不再次执行上一曲或下一曲。
                    if request_id in completed:
                        updated = read_player()
                    else:
                        try:
                            updated = execute_control(command, sent_at)
                        except (OSError, ValueError, subprocess.SubprocessError):
                            updated = False
                        completed[request_id] = isinstance(updated, dict)
                        if len(completed) > 64:
                            del completed[next(iter(completed))]
                        if not completed[request_id]:
                            updated = read_player()
                    # 复用刚验证的状态，并随同一次上报确认指令，减少原生读取与网络往返。
                    if updated.get('trackId') == snapshot.get('trackId') and updated.get('state') == 'ready':
                        updated.update(lines=snapshot['lines'], lyricsState=snapshot['lyricsState'])
                    send(url.rstrip('/') + '/api/music', token, updated | {
                        'ack': {'requestId': request_id, 'ok': completed[request_id]}})
                except (OSError, ValueError, subprocess.SubprocessError):
                    pass
            # 指令随上报取回，缩短空闲等待；耗时超过周期时不额外休眠或并发叠加采集。
            time.sleep(max(0, .25 - (time.monotonic() - started)))


if __name__ == '__main__':
    main()
