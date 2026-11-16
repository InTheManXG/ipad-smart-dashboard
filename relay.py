"""旧模式中转站：密钥留在本机配置，只向明确配置的 HTTPS 站点查询额度。"""
import json
import math
import os
from pathlib import Path
import tempfile
import threading
import time
import uuid
from urllib.error import HTTPError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

DATA = Path(os.environ.get('RELAY_DATA_DIR', str(Path(__file__).resolve().parent / '.relay-data')))
LOCK = threading.Lock()
CACHE = {}


class NoRedirect(HTTPRedirectHandler):
    # 禁止将带认证的请求重定向到其他地址。
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def read_keys():
    path = DATA / 'keys.json'
    return json.loads(path.read_text()) if path.exists() else []


def public_keys():
    with LOCK:
        # 短 Key 不展示首尾，避免两段拼接后泄露完整密钥。
        return [{'id': item['id'], 'name': item['name'],
                 'maskedKey': item['key'][:2] + '****' + item['key'][-4:] if len(item['key']) > 6 else '****'}
                for item in read_keys()]


def change_key(value):
    if not isinstance(value, dict):
        raise ValueError('invalid data')
    with LOCK:
        items = read_keys()
        identity = value.get('id')
        if identity is not None and not isinstance(identity, str):
            raise ValueError('invalid identity')
        item = next((item for item in items if item['id'] == identity), None)
        if identity and item is None:
            raise ValueError('unknown key')
        if value.get('action') == 'delete':
            if item is None:
                raise ValueError('unknown key')
            items.remove(item)
        elif value.get('action') == 'save':
            name, key = value.get('name'), value.get('key', '')
            if not isinstance(name, str) or not 1 <= len(name.strip()) <= 60:
                raise ValueError('invalid name')
            if not isinstance(key, str) or len(key) > 512 or (key and (not key.isascii() or any(c.isspace() or ord(c) < 33 or ord(c) == 127 for c in key))):
                raise ValueError('invalid key')
            if not item:
                if not key or len(items) >= 50:
                    raise ValueError('key required or limit reached')
                item = {'id': str(uuid.uuid4()), 'key': key}
                items.append(item)
            item['name'] = name.strip()
            if key:
                item['key'] = key
        else:
            raise ValueError('invalid action')
        DATA.mkdir(mode=0o700, parents=True, exist_ok=True)
        # 原子替换避免中途退出破坏已有配置，临时文件默认仅当前用户可读写。
        fd, path = tempfile.mkstemp(dir=DATA)
        try:
            with os.fdopen(fd, 'w') as output:
                json.dump(items, output, ensure_ascii=False)
                output.flush()
                os.fsync(output.fileno())
            os.replace(path, DATA / 'keys.json')
        finally:
            if os.path.exists(path):
                os.unlink(path)
        CACHE.pop(identity, None)
    return {'ok': True}


def number(value):
    return value if type(value) in (int, float) and abs(value) < 1e15 and math.isfinite(value) else None


def usage_url():
    path = DATA / 'station.json'
    if not path.exists():
        raise ValueError('station required')
    station = json.loads(path.read_text())
    if not isinstance(station, dict) or station.get('type') != 'sub2api' or not isinstance(station.get('url'), str):
        raise ValueError('invalid station')
    address = station['url'].strip().rstrip('/')
    parts = urlsplit(address)
    # 沿用原生站点格式，但旧服务端接口不允许回环 HTTP 或额外路径携带认证请求。
    if (parts.scheme != 'https' or not parts.hostname or parts.username is not None or parts.password is not None
            or parts.query or parts.fragment or parts.path not in ('', '/v1')
            or '\\' in address or any(character.isspace() or ord(character) < 32 for character in address)
            or (parts.port is not None and not 1 <= parts.port <= 65535)):
        raise ValueError('invalid station URL')
    return urlunsplit((parts.scheme, parts.netloc, '/v1/usage', '', ''))


def read_usage(identity, force=False):
    with LOCK:
        item = next((item for item in read_keys() if item['id'] == identity), None)
        if item is None:
            raise ValueError('unknown key')
        url, key = usage_url(), item['key']
        cached = CACHE.get(identity)
        if not force and cached and cached[0] == (url, key) and time.time() - cached[1]['updatedAt'] < 60:
            return cached[1]
    try:
        request = Request(url, headers={'Authorization': 'Bearer ' + key})
        with build_opener(NoRedirect).open(request, timeout=12) as response:
            raw = response.read(1_000_001)
        if len(raw) > 1_000_000:
            raise ValueError('oversized response')
        data = json.loads(raw)
        if not isinstance(data, dict) or data.get('isValid') is not True:
            raise ValueError('invalid key response')
        subscription = data.get('subscription') or {}
        if not isinstance(subscription, dict):
            raise ValueError('invalid subscription')
        # 仅返回展示所需字段，不透传上游内容，也不混用密钥与订阅的统计口径。
        result = {'remaining': number(data.get('remaining')), 'unit': data.get('unit') if data.get('unit') in ('USD', 'CNY') else '',
                  'dailyLimit': number(subscription.get('daily_limit_usd')),
                  'dailyUsed': number(subscription.get('daily_usage_usd')), 'updatedAt': time.time()}
    except HTTPError as error:
        result = {'error': 'Key 无效或无权访问' if error.code in (401, 403) else '中转站暂时不可用', 'updatedAt': time.time()}
    except (OSError, ValueError):
        result = {'error': '查询失败，请检查 Key 或稍后重试', 'updatedAt': time.time()}
    with LOCK:
        # 换钥、删除或切换站点后，旧回执不能冒充新配置的额度。
        current = next((item for item in read_keys() if item['id'] == identity), None)
        if current and current['key'] == key and usage_url() == url:
            CACHE[identity] = ((url, key), result)
        else:
            raise ValueError('key or station changed')
    return result
