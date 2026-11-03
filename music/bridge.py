"""读取 Mac 系统当前播放，匹配网易云时间轴歌词，上报到已认证的看板。"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import subprocess
import time
import unicodedata
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
MEDIA_CONTROL = '/opt/homebrew/bin/media-control'


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
    return {'state': 'ready', 'title': str(player.get('title', ''))[:300],
            'artist': str(player.get('artist', ''))[:300], 'album': str(player.get('album', ''))[:300], 'source': names[bundle],
            'playing': player.get('playing') is True, 'duration': max(0, min(duration, 86400)),
            'position': max(0, min(position, duration)), 'lyricsState': 'loading', 'lines': []}


def publish(url, token, snapshot):
    request = Request(url + '/api/music', data=json.dumps(snapshot, ensure_ascii=False).encode(),
                      headers={'X-Display-Token': token, 'Content-Type': 'application/json'})
    with urlopen(request, timeout=4) as response:
        if response.status != 200:
            raise OSError('music upload failed')


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
    cache, pending = {}, None
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
            futures = [uploads.submit(publish, url.rstrip('/'), token, snapshot) for url in args.url]
            for future in futures:
                try:
                    future.result()
                except (OSError, ValueError):
                    pass
            time.sleep(max(0, 1 - (time.monotonic() - started)))


if __name__ == '__main__':
    main()
