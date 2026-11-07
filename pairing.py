"""公开网页的配对中继：持久化凭据摘要，设备快照和短时指令只放内存。"""
import hashlib
import json
import math
import os
import re
import secrets
import sqlite3
import threading
import time
import uuid
from collections import OrderedDict
from urllib.parse import urlsplit, parse_qs
import music

CODE_TTL = 600
SESSION_TTL = 30 * 86400
FRESH_TTL = 15


class Failure(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def credential(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43,128}', value):
        raise Failure(401, 'unauthorized')
    return digest(value)


def identity(value):
    if not isinstance(value, str): raise Failure(400, 'invalid_identity')
    try:
        if str(uuid.UUID(value)) == value: return value
    except ValueError:
        pass
    raise Failure(400, 'invalid_identity')


def clean_status(value):
    if not isinstance(value, dict): raise Failure(400, 'invalid_snapshot')
    # 固定字段白名单，凭据和任意本地配置不会进入网页快照。
    result = {k: value[k] for k in ('state', 'plan', 'primary', 'secondary', 'conversationsTotal',
              'conversationsAvailable', 'quotaAvailable', 'cached', 'updatedAt') if k in value}
    tasks = value.get('conversations', [])
    if not isinstance(tasks, list) or len(tasks) > 8: raise Failure(400, 'invalid_tasks')
    result['conversations'] = []
    for task in tasks:
        if not isinstance(task, dict): raise Failure(400, 'invalid_tasks')
        result['conversations'].append({k: task[k] for k in ('threadId', 'title', 'state', 'unread', 'elapsedSeconds') if k in task})
    attention = value.get('attention')
    result['attention'] = {k: attention[k] for k in ('threadId', 'title') if k in attention} if isinstance(attention, dict) else None
    result['schema'] = 1
    return result


def clean_keys(value):
    if not isinstance(value, list) or len(value) > 50: raise Failure(400, 'invalid_keys')
    result = []
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get('name'), str) or len(item['name']) > 60:
            raise Failure(400, 'invalid_keys')
        identity(item.get('id'))
        # 公网页只收到备注、ID 和额度；完整 Key 留在 Mac 钥匙串。
        usage = item.get('usage', {})
        if not isinstance(usage, dict): raise Failure(400, 'invalid_usage')
        result.append({'id': item['id'], 'name': item['name'], 'usage': {
            k: usage[k] for k in ('remaining', 'unit', 'dailyLimit', 'dailyUsed', 'updatedAt', 'error') if k in usage}})
    return result


class Store:
    def __init__(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        os.chmod(path, 0o600)
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, secret TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
              code TEXT UNIQUE, expires REAL NOT NULL DEFAULT 0, seen REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS sessions (secret TEXT PRIMARY KEY, device TEXT NOT NULL, expires REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS screens (secret TEXT PRIMARY KEY REFERENCES sessions(secret) ON DELETE CASCADE,
              id TEXT UNIQUE NOT NULL, remark TEXT NOT NULL DEFAULT '', ua TEXT NOT NULL DEFAULT '', seen REAL NOT NULL DEFAULT 0);
        ''')
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.snapshots, self.pending = {}, {}
        self.buckets = OrderedDict()

    def close(self):
        self.db.close()

    def throttle(self, key, maximum, period=60):
        with self.lock:
            now = time.monotonic()
            count, start = self.buckets.pop(key, (0, now))
            if now - start >= period: count, start = 0, now
            self.buckets[key] = (count + 1, start)
            while len(self.buckets) > 4096: self.buckets.popitem(last=False)
            if count >= maximum: raise Failure(429, 'too_many_requests')

    def register(self, value):
        ident, token = identity(value.get('deviceId')), credential(value.get('deviceToken'))
        name = value.get('name', 'Mac App')
        if not isinstance(name, str) or not 1 <= len(name) <= 80: raise Failure(400, 'invalid_name')
        with self.lock, self.db:
            row = self.db.execute('SELECT secret FROM devices WHERE id=?', (ident,)).fetchone()
            if row:
                if row[0] != token: raise Failure(401, 'unauthorized')
            else:
                # 无账号注册只分配空设备，不授予任何现有设备的访问权；限制闲置注册占用。
                self.db.execute('DELETE FROM sessions WHERE expires < ?', (time.time(),))
                self.db.execute('DELETE FROM devices WHERE seen < ? AND id NOT IN (SELECT device FROM sessions)', (time.time()-86400,))
                if self.db.execute('SELECT COUNT(*) FROM devices').fetchone()[0] >= 10000: raise Failure(503, 'capacity_reached')
                self.db.execute('INSERT INTO devices(id,secret,name,seen) VALUES(?,?,?,?)', (ident, token, name, time.time()))
            self.db.execute('UPDATE devices SET name=?,seen=? WHERE id=?', (name, time.time(), ident))
            return self.state(ident)

    def _screen(self, hashed, user_agent=None):
        # 旧会话不失效；首次访问或管理列表时补登记，UA 仅作展示而非身份认证。
        self.db.execute('INSERT OR IGNORE INTO screens(secret,id) VALUES(?,?)', (hashed, str(uuid.uuid4())))
        if user_agent is not None:
            ua, now = user_agent[:1024], time.time()
            self.db.execute('UPDATE screens SET ua=?,seen=? WHERE secret=? AND (ua!=? OR seen<?)',
                            (ua, now, hashed, ua, now-60))

    def screens(self, ident):
        with self.lock, self.db:
            for (hashed,) in self.db.execute('SELECT secret FROM sessions WHERE device=? AND expires>?', (ident, time.time())).fetchall():
                self._screen(hashed)
            rows = self.db.execute('SELECT c.id,c.remark,c.ua,c.seen,s.expires FROM screens c JOIN sessions s ON c.secret=s.secret WHERE s.device=? AND s.expires>? ORDER BY c.seen DESC,c.id', (ident, time.time())).fetchall()
            return {'screens': [dict(zip(('id','remark','ua','seen','expires'), row)) for row in rows]}

    def remark(self, ident, value):
        screen_id, note = identity(value.get('id')), value.get('remark')
        if not isinstance(note, str) or len(note.strip()) > 80: raise Failure(400, 'invalid_remark')
        with self.lock, self.db:
            changed = self.db.execute('UPDATE screens SET remark=? WHERE id=? AND secret IN (SELECT secret FROM sessions WHERE device=? AND expires>?)', (note.strip(), screen_id, ident, time.time())).rowcount
            if not changed: raise Failure(404, 'screen_not_found')
            return {'ok': True}

    def authenticate(self, token, role, user_agent=None):
        hashed = credential(token)
        with self.lock, self.db:
            if role == 'device':
                row = self.db.execute('SELECT id FROM devices WHERE secret=?', (hashed,)).fetchone()
            else:
                row = self.db.execute('SELECT device FROM sessions WHERE secret=? AND expires>?', (hashed, time.time())).fetchone()
            if not row: raise Failure(401, 'unauthorized')
            if role == 'web': self._screen(hashed, user_agent)
            return row[0]

    def state(self, ident):
        with self.lock:
            row = self.db.execute('SELECT name,expires FROM devices WHERE id=?', (ident,)).fetchone()
            count = self.db.execute('SELECT COUNT(*) FROM sessions WHERE device=? AND expires>?', (ident, time.time())).fetchone()[0]
            return {'paired': count > 0, 'screenCount': count, 'name': row[0], 'expiresAt': row[1]}

    def code(self, ident):
        with self.lock, self.db:
            while True:
                raw = ''.join(secrets.choice('23456789ABCDEFGHJKMNPQRSTUVWXYZ') for _ in range(8))
                if not self.db.execute('SELECT 1 FROM devices WHERE code=?', (digest(raw),)).fetchone(): break
            expiry = time.time() + CODE_TTL
            self.db.execute('UPDATE devices SET code=?,expires=?,seen=? WHERE id=?', (digest(raw), expiry, time.time(), ident))
            return self.state(ident) | {'code': raw, 'expiresAt': expiry}

    def complete(self, value, user_agent=""):
        code = value.get('code')
        if not isinstance(code, str) or not re.fullmatch(r'[23456789A-HJKMNP-Z]{8}', code.upper()):
            raise Failure(401, 'invalid_pairing_code')
        with self.lock, self.db:
            row = self.db.execute('SELECT id,name FROM devices WHERE code=? AND expires>?', (digest(code.upper()), time.time())).fetchone()
            if not row: raise Failure(401, 'invalid_pairing_code')
            if self.state(row[0])['screenCount'] >= 16: raise Failure(409, 'screen_limit')
            token = secrets.token_urlsafe(32)
            self.db.execute('INSERT INTO sessions VALUES(?,?,?)', (digest(token), row[0], time.time()+SESSION_TTL))
            self._screen(digest(token), user_agent)
            # 消费与写会话同一事务，两个网页抢同一码最多一个成功。
            self.db.execute('UPDATE devices SET code=NULL,expires=0 WHERE id=?', (row[0],))
            return {'token': token, 'name': row[1]}

    def revoke(self, ident):
        with self.condition, self.db:
            self.db.execute('DELETE FROM sessions WHERE device=?', (ident,))
            self.db.execute('UPDATE devices SET code=NULL,expires=0 WHERE id=?', (ident,))
            for command in self.pending.get(ident, {}).values(): command['result'] = {'ok': False, 'error': 'revoked'}
            self.condition.notify_all()
            self.snapshots.pop(ident, None)
            return {'ok': True}

    def _remove_session(self, hashed):
        self.db.execute('DELETE FROM sessions WHERE secret=?', (hashed,))
        for commands in self.pending.values():
            for command in commands.values():
                if command['owner'] == hashed: command['result'] = {'ok': False, 'error': 'revoked'}
        self.condition.notify_all()

    def kick(self, ident, value):
        screen_id = identity(value.get('id'))
        with self.condition, self.db:
            row = self.db.execute('SELECT s.secret FROM sessions s JOIN screens c ON c.secret=s.secret WHERE c.id=? AND s.device=? AND s.expires>?', (screen_id, ident, time.time())).fetchone()
            if not row: raise Failure(404, 'screen_not_found')
            # 只撤销所属 Mac 的这一个会话，同时终止该会话等待中的指令。
            self._remove_session(row[0])
            return {'ok': True}

    def leave(self, token):
        with self.condition, self.db:
            self._remove_session(credential(token))
            return {'ok': True}

    def exchange(self, ident, value):
        # 状态和音乐由不同上传线程发送，合并快照必须与写入处于同一锁内。
        with self.condition:
            return self._exchange(ident, value)

    def _exchange(self, ident, value):
        previous = self.snapshots.get(ident)
        status = clean_status(value['status']) if 'status' in value else (previous[1] if previous else {'schema': 1, 'conversations': []})
        raw_music = value['music'] if 'music' in value else (previous[2] if previous else {'state': 'offline'})
        song = music.validate(raw_music)
        keys = clean_keys(value['keys']) if 'keys' in value else (previous[3] if previous else [])
        acks = value.get('acks', [])
        if not isinstance(acks, list) or len(acks) > 8: raise Failure(400, 'invalid_acks')
        now = time.monotonic()
        with self.condition:
            self.snapshots[ident] = (now, status, song, keys)
            # 清理掉线快照，长时间运行不随历史连接数增长。
            for key in list(self.snapshots):
                if now-self.snapshots[key][0] > 60: del self.snapshots[key]
            pending = self.pending.get(ident, {})
            for ack in acks:
                if not isinstance(ack, dict) or type(ack.get('ok')) is not bool: raise Failure(400, 'invalid_acks')
                command = pending.get(ack.get('requestId'))
                if command and command['deadline'] > now and command['result'] is None:
                    command['result'] = {'ok': ack['ok']}
                    if command['payload']['kind'] == 'music': command['result']['snapshot'] = song
                    if command['payload']['kind'] == 'usage' and isinstance(ack.get('usage'), dict):
                        command['result']['usage'] = ack['usage']
            commands = []
            for key, item in pending.items():
                # 只交给能处理该指令的上传线程，避免音乐线程抢走任务/额度指令。
                channel = 'music' if item['payload']['kind'] == 'music' else 'status'
                if channel not in value: continue
                if item['deadline'] > now and not item['sent'] and item['result'] is None:
                    item['sent'] = True
                    commands.append(item['payload'] | {'requestId': key, 'expiresIn': item['deadline']-now})
            self.condition.notify_all()
            return self.state(ident) | {'commands': commands}

    def read(self, ident, kind, key=None):
        with self.lock:
            item = self.snapshots.get(ident)
            if not item or time.monotonic()-item[0] > FRESH_TTL:
                if kind == 'music': return {'state': 'offline', 'enabled': bool(item and item[2].get('enabled', True))}
                raise Failure(503, 'device_offline')
            age, status, song, keys = time.monotonic()-item[0], item[1], item[2], item[3]
            if kind == 'status': return status | {'servedAt': time.time()}
            if kind == 'music':
                if song.get('playing'): return song | {'position': min(song['duration'], song['position']+age)}
                return song
            if kind == 'keys': return [{'id': k['id'], 'name': k['name']} for k in keys]
            record = next((k for k in keys if k['id'] == key), None)
            if not record: raise Failure(404, 'key_not_found')
            return record['usage']

    def command(self, ident, value, kind, owner, wait=8):
        if kind == 'open':
            target = identity(value.get('threadId'))
            status = self.read(ident, 'status')
            allowed = [i.get('threadId') for i in status.get('conversations', [])]
            if isinstance(status.get('attention'), dict): allowed.append(status['attention'].get('threadId'))
            if target not in allowed: raise Failure(409, 'stale_target')
            payload = {'kind': 'open', 'threadId': target}
        elif kind == 'music':
            if value.get('action') not in music.ACTIONS or not isinstance(value.get('trackId'), str) or not re.fullmatch('[a-f0-9]{64}', value['trackId']):
                raise Failure(400, 'invalid_command')
            song = self.read(ident, 'music')
            if song.get('state') != 'ready' or song.get('trackId') != value['trackId']: raise Failure(409, 'stale_target')
            payload = {'kind': 'music', 'action': value['action'], 'trackId': value['trackId']}
        elif kind == 'subscriptions':
            target = value.get('id')
            if target is not None and target not in ('paoluz', 'sc', 'just'):
                raise Failure(400, 'invalid_subscription')
            payload = {'kind': 'subscriptions', 'id': target}
        else:
            self.read(ident, 'usage', value.get('id'))
            payload = {'kind': 'usage', 'id': value['id']}
        with self.condition:
            # 多网页可能同时刷新额度；只读查询排队，控制指令仍避免重复执行。
            if kind == 'usage' and not self.condition.wait_for(lambda: not self.pending.get(ident), timeout=wait):
                raise Failure(409, 'device_busy')
            self.authenticate(owner, 'web')
            commands = self.pending.setdefault(ident, {})
            if commands: raise Failure(409, 'device_busy')
            request_id = str(uuid.uuid4())
            item = {'payload': payload, 'deadline': time.monotonic()+wait, 'sent': False, 'result': None, 'owner': credential(owner)}
            commands[request_id] = item
            try:
                self.condition.wait_for(lambda: item['result'] is not None, timeout=wait)
                if item['result'] is None: raise Failure(504, 'unconfirmed')
                if not item['result']['ok']: raise Failure(409, 'unconfirmed')
                # 撤销后不会因晚到的回执重新授予读取权限。
                self.authenticate(owner, 'web')
                return item['result'].get('usage', item['result'])
            finally:
                self.pending.pop(ident, None)
                self.condition.notify_all()


def route(handler):
    store = getattr(handler.server, 'pairing', None)
    path = urlsplit(handler.path).path
    if path == '/api/mode':
        handler.reply(200, json.dumps({'mode': 'pairing' if store else 'legacy'}).encode(), 'application/json')
        return True
    if not store or not path.startswith('/api/'): return False
    try:
        method = handler.command
        value = {}
        if method == 'POST':
            handler.connection.settimeout(8)
            if handler.headers.get('Transfer-Encoding') or len(handler.headers.get_all('Content-Length', [])) != 1:
                raise Failure(400, 'invalid_body')
            length = int(handler.headers.get('Content-Length', '0'))
            limit = 512000 if path == '/api/device/exchange' else 1024
            if not 0 < length <= limit: raise Failure(413, 'body_too_large')
            value = json.loads(handler.rfile.read(length), parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            if not isinstance(value, dict): raise Failure(400, 'invalid_body')
        peer = handler.client_address[0]
        # 单层受信任反代覆盖 X-Real-IP；直连客户端提供的转发头不能绕过限流。
        if os.environ.get('PAIRING_TRUST_PROXY') == '1' and peer in ('127.0.0.1', '::1'):
            peer = handler.headers.get('X-Real-IP', peer)
        if method == 'POST' and path == '/api/pairing/register':
            store.throttle(('register', peer), 10, 600); store.throttle(('register-global', ''), 100, 600)
            result = store.register(value)
        elif method == 'POST' and path == '/api/pairing/complete':
            store.throttle(('complete', peer), 10, 60); store.throttle(('complete-global', ''), 300, 60)
            result = store.complete(value, handler.headers.get('User-Agent', ''))
        elif path in ('/api/device/exchange', '/api/pairing/code', '/api/pairing/revoke', '/api/pairing/device', '/api/pairing/screens', '/api/pairing/screen', '/api/pairing/kick'):
            ident = store.authenticate(handler.headers.get('X-Device-Token', ''), 'device')
            store.throttle(('device', ident), 600, 60)
            if path == '/api/device/exchange' and method == 'POST': result = store.exchange(ident, value)
            elif path == '/api/pairing/code' and method == 'POST': result = store.code(ident)
            elif path == '/api/pairing/revoke' and method == 'POST': result = store.revoke(ident)
            elif path == '/api/pairing/device' and method == 'GET': result = store.state(ident)
            elif path == '/api/pairing/screens' and method == 'GET': result = store.screens(ident)
            elif path == '/api/pairing/screen' and method == 'POST': result = store.remark(ident, value)
            elif path == '/api/pairing/kick' and method == 'POST': result = store.kick(ident, value)
            else: raise Failure(405, 'method_not_allowed')
        else:
            token = handler.headers.get('X-Pairing-Token', '')
            ident = store.authenticate(token, 'web', handler.headers.get('User-Agent', ''))
            store.throttle(('web', digest(token)), 360, 60)
            if path == '/api/pairing/leave' and method == 'POST': result = store.leave(token)
            elif path == '/api/pairing/status' and method == 'GET': result = store.state(ident)
            elif path == '/api/status' and method == 'GET': result = store.read(ident, 'status')
            elif path == '/api/music' and method == 'GET': result = store.read(ident, 'music')
            elif path == '/api/relay/keys' and method == 'GET': result = store.read(ident, 'keys')
            elif path == '/api/relay/usage' and method == 'GET':
                query = parse_qs(urlsplit(handler.path).query); key = query.get('id', [''])[0]
                result = store.command(ident, {'id': key}, 'usage', token) if query.get('refresh') == ['1'] else store.read(ident, 'usage', key)
            elif path == '/api/subscriptions' and method == 'GET':
                result = [{'id': 'paoluz', 'remark': 'Paoluz'}, {'id': 'sc', 'remark': '顺畅网络'}, {'id': 'just', 'remark': '管人痴·ZDQ'}]
            elif path == '/api/subscriptions/update' and method == 'POST':
                result = store.command(ident, value, 'subscriptions', token, wait=300)
            elif path in ('/api/open', '/api/music/control') and method == 'POST':
                result = store.command(ident, value, 'open' if path == '/api/open' else 'music', token)
            else:
                # 配对身份绝不能回落到旧的全局 Key、订阅脚本或音乐写入接口。
                raise Failure(404, 'unsupported')
        handler.reply(200, json.dumps(result, ensure_ascii=False, allow_nan=False).encode(), 'application/json')
    except Failure as error:
        handler.reply(error.status, json.dumps({'error': error.message}).encode(), 'application/json')
    except (ValueError, TypeError, KeyError): handler.reply(400, b'{"error":"invalid_request"}', 'application/json')
    except (OSError, sqlite3.Error): handler.reply(503, b'{"error":"storage_unavailable"}', 'application/json')
    return True
