"""音乐快照只保存在内存；歌曲、歌词与播放进度不写入访问日志。"""
import math
import threading
import time

_lock = threading.Lock()
_snapshot = None
_received = 0


def validate(value):
    if not isinstance(value, dict) or value.get('state') not in ('idle', 'ready', 'unavailable'):
        raise ValueError('invalid music state')
    result = {'state': value['state']}
    if value['state'] != 'ready':
        return result
    for key in ('title', 'artist', 'source', 'lyricsState'):
        text = value.get(key)
        if not isinstance(text, str) or len(text) > 300:
            raise ValueError('invalid music text')
        result[key] = text
    if result['lyricsState'] not in ('ready', 'loading', 'missing', 'error'):
        raise ValueError('invalid lyrics state')
    if type(value.get('playing')) is not bool:
        raise ValueError('invalid playback state')
    result['playing'] = value['playing']
    for key in ('position', 'duration'):
        number = value.get(key)
        if type(number) not in (int, float) or not math.isfinite(number) or not 0 <= number <= 86400:
            raise ValueError('invalid timeline')
        result[key] = number
    lines = value.get('lines')
    if not isinstance(lines, list) or len(lines) > 1000:
        raise ValueError('invalid lyrics')
    result['lines'] = []
    previous = -1
    for line in lines:
        if not isinstance(line, dict):
            raise ValueError('invalid lyric line')
        stamp, text = line.get('time'), line.get('text')
        if (type(stamp) not in (int, float) or not math.isfinite(stamp) or
                not previous <= stamp <= 86400 or stamp < 0 or
                not isinstance(text, str) or len(text) > 300):
            raise ValueError('invalid lyric line')
        result['lines'].append({'time': stamp, 'text': text})
        previous = stamp
    return result


def put(value):
    global _snapshot, _received
    clean = validate(value)
    with _lock:
        _snapshot, _received = clean, time.monotonic()


def get():
    with _lock:
        age = time.monotonic() - _received
        # Mac 休眠或采集退出后，不允许客户端继续推演旧进度。
        if _snapshot is None or age > 8:
            return {'state': 'offline'}
        result = dict(_snapshot)
    if result['state'] == 'ready' and result['playing']:
        result['position'] = min(result['duration'], result['position'] + age)
    return result
