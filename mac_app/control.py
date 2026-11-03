"""Mac App 的本地控制入口；仅接受固定动作，不提供网络命令执行服务。"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / '.mac-app.json'
AGENTS = Path.home() / 'Library/LaunchAgents'
MUSIC = 'com.iamxg.ipad-music'
APP = 'com.iamxg.ipad-control'
DOMAIN = f'gui/{os.getuid()}'
DOCKER = '/Applications/OrbStack.app/Contents/MacOS/xbin/docker'
APP_PATH = ROOT / '.build/iPad 控制台.app'


def run(args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=45, cwd=ROOT)
    if check and result.returncode:
        # 子进程原始输出可能包含配置内容，不回传到界面或日志。
        raise ValueError('服务操作失败，请确认 OrbStack 已运行、音乐服务已安装')
    return result


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def settings():
    return json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}


def connection(value=None):
    value = settings() if value is None else value
    url = value.get('url', 'https://ipad.iamxg.com').rstrip('/')
    parsed = urlsplit(url)
    if (parsed.scheme not in ('http', 'https') or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path or any(c.isspace() for c in url)
            or (parsed.scheme == 'http' and parsed.hostname not in ('127.0.0.1', 'localhost', '::1'))):
        raise ValueError('地址仅支持 HTTPS 站点或本机 HTTP，不含路径、账号和查询参数')
    parsed.port  # 让非法端口在发送口令前失败。
    token = value.get('token') or (ROOT / '.display-token').read_text().strip()
    if not isinstance(token, str) or not token or len(token) > 512 or not token.isascii() or any(c.isspace() for c in token):
        raise ValueError('访问口令格式不正确')
    return url, token


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None  # 不把访问口令转发给重定向地址。


def api(body=None, config=None):
    url, token = connection(config)
    request = Request(url + '/api/relay/keys',
                      headers={'X-Display-Token': token, 'Content-Type': 'application/json'},
                      data=json.dumps(body).encode() if body is not None else None)
    try:
        with build_opener(NoRedirect).open(request, timeout=15) as response:
            return json.load(response)
    except HTTPError as error:
        raise ValueError('访问口令无效' if error.code == 401 else '看板拒绝操作，请检查输入') from None
    except (URLError, TimeoutError):
        raise ValueError('无法连接看板，请检查地址和服务状态') from None


def agent_state(label):
    result = run(['/bin/launchctl', 'list', label], check=False)
    return result.returncode == 0 and '"PID"' in result.stdout


def music_plist():
    path = AGENTS / (MUSIC + '.plist')
    if not path.exists():
        raise ValueError('音乐服务尚未安装，请先运行 deploy/install-music.py')
    value = plistlib.loads(path.read_bytes())
    # 只接管本项目的采集器，避免操作同名但属于其他目录的服务。
    if value.get('ProgramArguments', [None, None])[1] != str(ROOT / 'music/bridge.py'):
        raise ValueError('音乐服务属于其他项目路径，请先重新安装本项目音乐服务')
    return path, value


def snapshot():
    result = run([DOCKER, 'inspect', '--format', '{{.State.Running}}', 'codex-ipad-local'], check=False)
    music_path = AGENTS / (MUSIC + '.plist')
    music_config = plistlib.loads(music_path.read_bytes()) if music_path.exists() else {}
    return {'url': settings().get('url', 'https://ipad.iamxg.com'),
            'dashboard': '运行中' if result.returncode == 0 and result.stdout.strip() == 'true' else '未运行或 OrbStack 不可用',
            'music': '运行中' if agent_state(MUSIC) else '已停止',
            'musicLogin': bool(music_config.get('RunAtLoad')),
            'appLogin': (AGENTS / (APP + '.plist')).exists()}


def dispatch(value):
    action = value.get('action')
    if action == 'status':
        return snapshot()
    if action == 'keys':
        return {'keys': api()}
    if action == 'connection-save':
        candidate = {'url': value.get('url', ''), 'token': value.get('token', '')}
        # 留空只沿用当前口令；测试成功后才落盘，不改共享的服务口令。
        candidate['token'] = candidate['token'] or settings().get('token', '')
        url, _ = connection(candidate)
        api(config=candidate)
        candidate['url'] = url
        atomic_write(SETTINGS, json.dumps(candidate).encode())
    elif action in ('key-save', 'key-delete'):
        body = {key: value[key] for key in ('id', 'name', 'key') if key in value}
        body['action'] = 'save' if action == 'key-save' else 'delete'
        api(body)
    elif action == 'dashboard-start':
        run([DOCKER, 'compose', '-f', str(ROOT / 'compose.local.yaml'), 'up', '-d'])
    elif action == 'dashboard-stop':
        run([DOCKER, 'compose', '-f', str(ROOT / 'compose.local.yaml'), 'stop'])
    elif action in ('music-start', 'music-stop', 'music-login'):
        path, config = music_plist()
        target = DOMAIN + '/' + MUSIC
        if action == 'music-stop':
            result = run(['/bin/launchctl', 'bootout', target], check=False)
            if result.returncode and agent_state(MUSIC):
                raise ValueError('音乐服务停止失败')
        elif action == 'music-start':
            if run(['/bin/launchctl', 'list', MUSIC], check=False).returncode:
                run(['/bin/launchctl', 'bootstrap', DOMAIN, str(path)])
            run(['/bin/launchctl', 'kickstart', target])
        else:
            enabled = value.get('enabled')
            if type(enabled) is not bool:
                raise ValueError('登录启动必须为布尔值')
            running = agent_state(MUSIC)
            old = path.read_bytes()
            config.update(RunAtLoad=enabled, KeepAlive=enabled)
            atomic_write(path, plistlib.dumps(config))
            try:
                run(['/bin/launchctl', 'bootout', target], check=False)
                # 修改下次登录行为不改变当前启停意图。
                if running:
                    run(['/bin/launchctl', 'bootstrap', DOMAIN, str(path)])
                    run(['/bin/launchctl', 'kickstart', target])
            except Exception:
                atomic_write(path, old)
                run(['/bin/launchctl', 'bootstrap', DOMAIN, str(path)], check=False)
                raise
    elif action == 'app-login':
        enabled = value.get('enabled')
        if type(enabled) is not bool:
            raise ValueError('登录启动必须为布尔值')
        path = AGENTS / (APP + '.plist')
        if enabled:
            executable = APP_PATH / 'Contents/MacOS/iPadControl'
            if not executable.is_file():
                raise ValueError('请先构建 Mac App')
            atomic_write(path, plistlib.dumps({'Label': APP, 'ProgramArguments': [str(executable)],
                                              'RunAtLoad': True, 'ProcessType': 'Interactive'}))
        else:
            path.unlink(missing_ok=True)
        # 仅配置下次登录，不在本次会话再启动一个 App 实例。
    else:
        raise ValueError('不支持的操作')
    return {'ok': True}


if __name__ == '__main__':
    try:
        payload = sys.stdin.buffer.read(8193)
        if len(payload) > 8192:
            raise ValueError('请求过大')
        value = json.loads(payload)
        if not isinstance(value, dict):
            raise ValueError('请求格式错误')
        print(json.dumps(dispatch(value), ensure_ascii=False))
    except ValueError as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False))
    except (OSError, subprocess.SubprocessError, TypeError, KeyError, IndexError):
        print(json.dumps({'error': '本地操作失败，请检查服务安装和文件权限'}, ensure_ascii=False))
