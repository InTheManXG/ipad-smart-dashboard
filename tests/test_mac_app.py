import json
from pathlib import Path
import plistlib
import stat
import tempfile
import threading
import unittest
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from types import SimpleNamespace

from mac_app import control
from server import Handler


class MacAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / '.display-token').write_text('test-only')
        for attribute, value in [('ROOT', self.root), ('SETTINGS', self.root / '.mac-app.json'),
                                 ('AGENTS', self.root / 'LaunchAgents')]:
            patcher = patch.object(control, attribute, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def start_server(self, handler=Handler):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        self.server.token = 'test-only'
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        return f'http://127.0.0.1:{self.server.server_port}'

    def test_connection_validation(self):
        for url in ['http://example.com', 'https://user:pass@example.com',
                    'https://example.com/path', 'https://example.com?secret=1',
                    'https://example.com#key', 'file:///tmp', 'https://example.com:bad']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                control.connection({'url': url})
        self.assertEqual(control.connection({'url': 'http://127.0.0.1:18088/'})[0],
                         'http://127.0.0.1:18088')

    def test_keys_roundtrip_and_private_settings(self):
        url = self.start_server()
        with patch('relay.DATA', self.root / 'keys'):
            control.dispatch({'action': 'connection-save', 'url': url})
            self.assertEqual(stat.S_IMODE(control.SETTINGS.stat().st_mode), 0o600)
            self.assertNotIn('token', control.dispatch({'action': 'keys'}))
            control.dispatch({'action': 'key-save', 'name': '测试', 'key': 'test-secret-key'})
            item = control.dispatch({'action': 'keys'})['keys'][0]
            self.assertNotIn('test-secret-key', json.dumps(item))
            control.dispatch({'action': 'key-save', 'id': item['id'], 'name': '改名', 'key': ''})
            self.assertEqual(control.dispatch({'action': 'keys'})['keys'][0]['name'], '改名')
            self.assertEqual(json.loads((self.root / 'keys/keys.json').read_text())[0]['key'], 'test-secret-key')
            control.dispatch({'action': 'key-delete', 'id': item['id']})
            self.assertEqual(control.dispatch({'action': 'keys'}), {'keys': []})

    def test_failed_connection_preserves_previous_settings(self):
        url = self.start_server()
        original = b'{"url":"https://ipad.iamxg.com"}'
        control.SETTINGS.write_bytes(original)
        with self.assertRaisesRegex(ValueError, '口令无效'):
            control.dispatch({'action': 'connection-save', 'url': url, 'token': 'wrong'})
        self.assertEqual(control.SETTINGS.read_bytes(), original)

    def test_redirect_does_not_forward_token(self):
        visited = []

        class Redirect(Handler):
            def do_GET(self):
                visited.append(self.path)
                self.send_response(302)
                self.send_header('Location', '/stolen')
                self.end_headers()

        url = self.start_server(Redirect)
        with self.assertRaises(ValueError):
            control.api(config={'url': url})
        self.assertEqual(visited, ['/api/relay/keys'])

    def music_config(self):
        path = control.AGENTS / (control.MUSIC + '.plist')
        value = {'ProgramArguments': ['/usr/bin/python3', str(self.root / 'music/bridge.py')],
                 'RunAtLoad': True, 'KeepAlive': True}
        control.atomic_write(path, plistlib.dumps(value))
        return path

    def test_login_toggle_preserves_stopped_service(self):
        path = self.music_config()
        with patch.object(control, 'agent_state', return_value=False), patch.object(control, 'run') as run:
            control.dispatch({'action': 'music-login', 'enabled': False})
            self.assertFalse(plistlib.loads(path.read_bytes())['KeepAlive'])
            self.assertFalse(any('bootstrap' in call.args[0] for call in run.call_args_list))

    def test_login_reload_failure_restores_original(self):
        path = self.music_config()
        original = path.read_bytes()

        def run(args, check=True):
            if 'bootstrap' in args and check:
                raise ValueError('模拟启动失败')
            return SimpleNamespace(returncode=0)

        with patch.object(control, 'agent_state', return_value=True), patch.object(control, 'run', side_effect=run):
            with self.assertRaises(ValueError):
                control.dispatch({'action': 'music-login', 'enabled': False})
        self.assertEqual(path.read_bytes(), original)

    def test_shared_service_path_is_not_overwritten(self):
        path = self.music_config()
        value = plistlib.loads(path.read_bytes())
        value['ProgramArguments'][1] = '/another/project/music/bridge.py'
        path.write_bytes(plistlib.dumps(value))
        with self.assertRaisesRegex(ValueError, '其他项目'):
            control.dispatch({'action': 'music-stop'})

    def test_reject_unknown_command(self):
        with patch.object(control, 'run') as run, self.assertRaises(ValueError):
            control.dispatch({'action': 'shell', 'command': 'echo unsafe'})
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
