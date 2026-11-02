"""iPad 看板：展示状态并请求 Mac 打开当前待处理对话，不提供任意命令接口。"""
import hmac
import json
import os
from pathlib import Path
import secrets
import uuid
from urllib.parse import urlsplit, parse_qs
import relay
from urllib.error import HTTPError
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
CONFIG = Path.home() / 'Library/Application Support/ESP32CodexBridge/config.json'
FILES = {'/': ('index.html', 'text/html'), '/app.js': ('app.js', 'text/javascript'), '/relay.js': ('relay.js', 'text/javascript'),
         '/style.css': ('style.css', 'text/css'), '/manifest.json': ('manifest.json', 'application/manifest+json'),
         '/icon.svg': ('icon.svg', 'image/svg+xml'), '/codex-icon.png': ('codex-icon.png', 'image/png')}


def authorized(header, token):
    return hmac.compare_digest(header.encode(), token.encode())


def read_status():
    config = json.loads(CONFIG.read_text()) if not os.environ.get('CODEX_STATUS_TOKEN') else os.environ
    request = Request(os.environ.get('STATUS_URL', 'http://127.0.0.1:8787/status'), headers={
        'X-Codex-Status-Token': config['CODEX_STATUS_TOKEN']})
    with urlopen(request, timeout=5) as response:
        data = json.load(response)
    if not isinstance(data, dict) or data.get('schema') != 1:
        raise ValueError('unsupported snapshot')
    # 【业务逻辑】仅传递待处理对话标识，供用户主动点击打开；不暴露桥接密钥。
    return {key: data[key] for key in ('state', 'message', 'plan', 'primary', 'secondary',
        'conversations', 'conversationsTotal', 'conversationsAvailable', 'quotaAvailable',
        'cached', 'updatedAt', 'servedAt', 'attention') if key in data}


def open_attention(thread_id):
    # 【业务逻辑】只允许打开最新列表或提醒中的对话，中继和 Mac 还会再次校验。
    snapshot = read_status()
    attention = snapshot.get('attention')
    allowed = {item.get('threadId') for item in snapshot.get('conversations', [])}
    if isinstance(attention, dict):
        allowed.add(attention.get('threadId'))
    if thread_id not in allowed:
        return False
    config = json.loads(CONFIG.read_text()) if not os.environ.get('CODEX_STATUS_TOKEN') else os.environ
    status_url = os.environ.get('STATUS_URL', config.get('url', '').rsplit('/', 1)[0] + '/status')
    request = Request(status_url.rsplit('/', 1)[0] + '/open',
        data=json.dumps({'threadId': thread_id}).encode(),
        headers={'Content-Type': 'application/json', 'X-Codex-Status-Token': config['CODEX_STATUS_TOKEN']})
    try:
        with urlopen(request, timeout=15) as response:
            return json.load(response).get('ok') is True
    except HTTPError as error:
        if error.code == 409:
            return False
        raise


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # 不将认证信息或请求路径写入日志。

    def reply(self, code, body, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type + '; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'")
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def relay_api(self):
        if not authorized(self.headers.get('X-Display-Token', ''), self.server.token):
            self.reply(401, b'{}', 'application/json')
            return
        try:
            if self.command == 'POST':
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 4096:
                    raise ValueError('invalid body size')
                self.connection.settimeout(5)
                result = relay.change_key(json.loads(self.rfile.read(length)))
            elif urlsplit(self.path).path == '/api/relay/usage':
                result = relay.read_usage(parse_qs(urlsplit(self.path).query).get('id', [''])[0])
            else:
                result = relay.public_keys()
            self.reply(200, json.dumps(result, ensure_ascii=False).encode(), 'application/json')
        except (ValueError, TypeError):
            self.reply(400, b'{"error":"invalid_request"}', 'application/json')
        except OSError:
            self.reply(503, b'{"error":"storage_unavailable"}', 'application/json')

    def do_POST(self):
        if self.path == '/api/relay/keys':
            self.relay_api()
            return
        if self.path != '/api/open':
            self.reply(404, b'{}', 'application/json')
            return
        if not authorized(self.headers.get('X-Display-Token', ''), self.server.token):
            self.reply(401, b'{}', 'application/json')
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 256:
                raise ValueError('invalid body size')
            self.connection.settimeout(5)
            value = json.loads(self.rfile.read(length))
            thread_id = value.get('threadId') if isinstance(value, dict) else None
            if not isinstance(thread_id, str) or str(uuid.UUID(thread_id)) != thread_id:
                raise ValueError('invalid identity')
        except (ValueError, OSError):
            self.reply(400, b'{}', 'application/json')
            return
        try:
            success = open_attention(thread_id)
            self.reply(200 if success else 409, json.dumps({'ok': success}).encode(), 'application/json')
        except (OSError, ValueError, KeyError):
            self.reply(503, b'{}', 'application/json')

    def do_GET(self):
        if urlsplit(self.path).path in ('/api/relay/keys', '/api/relay/usage'):
            self.relay_api()
            return
        if self.path == '/api/status':
            if not authorized(self.headers.get('X-Display-Token', ''), self.server.token):
                self.reply(401, b'{"error":"unauthorized"}', 'application/json')
                return
            try:
                self.reply(200, json.dumps(read_status(), ensure_ascii=False).encode(), 'application/json')
            except (OSError, ValueError, KeyError):
                self.reply(503, b'{"error":"bridge_unavailable"}', 'application/json')
        elif self.path in FILES:
            name, kind = FILES[self.path]
            self.reply(200, (ROOT / 'web' / name).read_bytes(), kind)
        else:
            self.reply(404, b'Not found', 'text/plain')


def main():
    # 独立的看板口令可撤销，不复用具备其他能力的桥接器令牌。
    path = ROOT / '.display-token'
    if not path.exists():
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(secrets.token_urlsafe(24))
    server = ThreadingHTTPServer((os.environ.get('DISPLAY_BIND', '0.0.0.0'), 18086), Handler)
    server.token = path.read_text().strip()
    print('iPad 看板已启动，端口 18086', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
