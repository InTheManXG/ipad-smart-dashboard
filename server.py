"""iPad 看板：只代理本机状态快照，不提供任务写入或文件访问接口。"""
import hmac
import json
import os
from pathlib import Path
import secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
CONFIG = Path.home() / 'Library/Application Support/ESP32CodexBridge/config.json'
FILES = {'/': ('index.html', 'text/html'), '/app.js': ('app.js', 'text/javascript'),
         '/style.css': ('style.css', 'text/css'), '/manifest.json': ('manifest.json', 'application/manifest+json'),
         '/icon.svg': ('icon.svg', 'image/svg+xml')}


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
    # 浏览器只需展示字段，不传递原桥接器的控制入口和对话标识。
    return {key: data[key] for key in ('state', 'message', 'plan', 'primary', 'secondary',
        'conversations', 'conversationsTotal', 'conversationsAvailable', 'quotaAvailable',
        'cached', 'updatedAt', 'servedAt') if key in data}


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

    def do_GET(self):
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
