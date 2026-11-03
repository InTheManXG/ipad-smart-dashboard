"""音乐快照只保存在内存；歌曲、歌词与播放进度不写入访问日志。"""
import math
import re
import threading
import time
import uuid

_lock = threading.Lock()
_snapshot = None
_received = 0
_control_condition = threading.Condition(_lock)
_command = None
ACTIONS = ('previous', 'replay', 'play', 'pause', 'next')


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
    track_id = value.get('trackId', '')
    if not isinstance(track_id, str) or (track_id and not re.fullmatch(r'[0-9a-f]{64}', track_id)):
        raise ValueError('invalid track identity')
    result['trackId'] = track_id
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


def control(value):
    global _command
    if (not isinstance(value, dict) or value.get('action') not in ACTIONS or
            not isinstance(value.get('trackId'), str) or not re.fullmatch(r'[0-9a-f]{64}', value['trackId'])):
        raise ValueError('invalid music command')
    with _control_condition:
        if (_snapshot is None or _snapshot.get('state') != 'ready' or time.monotonic() - _received > 8 or
                _snapshot.get('trackId') != value['trackId'] or _command is not None):
            return {'ok': False, 'error': 'unavailable'}
        command = {'requestId': str(uuid.uuid4()), 'action': value['action'], 'trackId': value['trackId'],
                   'expires': time.monotonic() + 8, 'result': None}
        _command = command
        _control_condition.notify_all()
        try:
            _control_condition.wait_for(lambda: command['result'] is not None, timeout=8)
            return {'ok': command['result'] is True, 'error': None if command['result'] is True else 'unconfirmed'}
        finally:
            # 超时即撤销，不在 Mac 恢复网络后补执行之前的点按。
            _command = None


def pending_control(wait=0):
    with _control_condition:
        # 上报连接短暂等候点按，指令到达立即唤醒，不必等下一轮播放器采集。
        if wait and _command is None:
            _control_condition.wait_for(lambda: _command is not None, timeout=wait)
        if not _command or _command['result'] is not None or _command['expires'] <= time.monotonic():
            return None
        return {key: _command[key] for key in ('requestId', 'action', 'trackId')} | {
            'expiresIn': _command['expires'] - time.monotonic()}


def acknowledge(value):
    if (not isinstance(value, dict) or not isinstance(value.get('requestId'), str) or
            type(value.get('ok')) is not bool):
        raise ValueError('invalid acknowledgement')
    with _control_condition:
        if _command and value['requestId'] == _command['requestId'] and time.monotonic() < _command['expires']:
            _command['result'] = value['ok']
            _control_condition.notify_all()


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
