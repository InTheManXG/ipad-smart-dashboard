import json
from pathlib import Path
import tempfile
import threading
import unittest
import uuid
from unittest.mock import patch
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from http.server import ThreadingHTTPServer
import pairing
from server import Handler, authorized, open_attention


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.token = 'test-only'
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_authentication_and_paths(self):
        self.assertFalse(authorized('', 'test-only'))
        for path in ['/api/status', '/../../server.py', '/.display-token']:
            with self.assertRaises(HTTPError) as error:
                urlopen(self.url + path)
            self.assertIn(error.exception.code, [401, 404])

    def test_status_and_failure(self):
        request = Request(self.url + '/api/status', headers={'X-Display-Token': 'test-only'})
        with patch('server.read_status', return_value={'state': 'waiting'}):
            with urlopen(request) as response:
                self.assertEqual(json.load(response)['state'], 'waiting')
                self.assertEqual(response.headers['Cache-Control'], 'no-store')
        with patch('server.read_status', side_effect=OSError):
            with self.assertRaises(HTTPError) as error:
                urlopen(request)
            self.assertEqual(error.exception.code, 503)

    def test_open_auth_validation_and_ack(self):
        identity = '01a186f1-b672-7be0-8d12-a30a3f6dd686'
        for token, body, expected in [('', {'threadId': identity}, 401),
                                       ('test-only', {'threadId': 'file:///tmp'}, 400)]:
            request = Request(self.url + '/api/open', data=json.dumps(body).encode(),
                              headers={'X-Display-Token': token})
            with patch('server.open_attention') as action:
                with self.assertRaises(HTTPError) as error:
                    urlopen(request)
                self.assertEqual(error.exception.code, expected)
                action.assert_not_called()
        request = Request(self.url + '/api/open', data=json.dumps({'threadId': identity}).encode(),
                          headers={'X-Display-Token': 'test-only'})
        with patch('server.open_attention', return_value=True):
            with urlopen(request) as response:
                self.assertEqual(json.load(response), {'ok': True})
        with patch('server.open_attention', return_value=False):
            with self.assertRaises(HTTPError) as error:
                urlopen(request)
            self.assertEqual(error.exception.code, 409)
        with patch('server.open_attention', side_effect=OSError):
            with self.assertRaises(HTTPError) as error:
                urlopen(request)
            self.assertEqual(error.exception.code, 503)

    def test_stale_attention_never_dispatches(self):
        with patch('server.read_status', return_value={'attention': None}), patch('server.urlopen') as send:
            self.assertFalse(open_attention('01a186f1-b672-7be0-8d12-a30a3f6dd686'))
            send.assert_not_called()

    def test_page(self):
        with urlopen(self.url) as response:
            self.assertIn('任务现场', response.read().decode())


    def test_removed_subscription_routes(self):
        headers = {'X-Display-Token': 'test-only'}
        for path, data in [('/api/subscriptions', None), ('/api/subscriptions/update', b'{}'), ('/subscriptions.js', None)]:
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + path, data=data, headers=headers))
            self.assertEqual(error.exception.code, 404)

    def test_legacy_manager_permissions(self):
        with urlopen(Request(self.url + '/api/permissions', headers={'X-Display-Token': 'test-only'})) as response:
            self.assertTrue(json.load(response)['controlAllowed'])
        with self.assertRaises(HTTPError) as error:
            urlopen(self.url + '/api/permissions')
        self.assertEqual(error.exception.code, 401)

    def test_pairing_control_permission_http_boundary(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        store = pairing.Store(Path(folder.name) / 'pairing.sqlite')
        self.addCleanup(store.close)
        self.server.pairing = store

        def request(path, value=None, headers=None, expected=200):
            body = json.dumps(value).encode() if value is not None else None
            call = Request(self.url + path, data=body, headers=headers or {})
            try:
                response = urlopen(call)
            except HTTPError as error:
                response = error
            with response:
                self.assertEqual(response.code, expected, path)
                return json.load(response)

        device_id, other_id = str(uuid.uuid4()), str(uuid.uuid4())
        device_headers = {'X-Device-Token': 'a' * 64}
        other_headers = {'X-Device-Token': 'b' * 64}
        request('/api/pairing/register', {'deviceId': device_id, 'deviceToken': 'a' * 64})
        request('/api/pairing/register', {'deviceId': other_id, 'deviceToken': 'b' * 64})
        code = request('/api/pairing/code', {}, device_headers)['code']
        token = request('/api/pairing/complete', {'code': code}, {'User-Agent': 'Permission test'})['token']
        web_headers = {'X-Pairing-Token': token}
        permission = request('/api/permissions', headers=web_headers)
        self.assertFalse(permission['controlAllowed'])
        request('/api/permissions', expected=401)
        change = {'id': permission['screenId'], 'controlAllowed': True}

        # 网页不能给自己授权，另一台 Mac 也不能更改本机屏幕的权限。
        request('/api/pairing/permission', change, web_headers, expected=401)
        request('/api/pairing/permission', change, other_headers, expected=404)
        request('/api/pairing/permission', change | {'controlAllowed': 'true'}, device_headers, expected=400)
        request('/api/open', {'threadId': str(uuid.uuid4())}, web_headers, expected=403)
        request('/api/music/control', {'action': 'play'}, web_headers, expected=403)
        request('/api/console/run', {'id': str(uuid.uuid4())}, web_headers, expected=403)

        request('/api/pairing/permission', change, device_headers)
        self.assertTrue(request('/api/permissions', headers=web_headers)['controlAllowed'])
        store.exchange(device_id, {'status': {}, 'music': {'state': 'idle', 'enabled': False}})
        for path in ('/api/status', '/api/music'):
            snapshot = request(path, headers=web_headers)
            self.assertTrue(snapshot['controlAllowed'])
            self.assertEqual(snapshot['screenId'], permission['screenId'])
        request('/api/pairing/permission', change | {'controlAllowed': False}, device_headers)
        self.assertFalse(request('/api/permissions', headers=web_headers)['controlAllowed'])
        request('/api/subscriptions', headers=web_headers, expected=404)
        request('/api/subscriptions/update', {}, web_headers, expected=404)
        self.assertEqual(request('/api/pairing/leave', {}, web_headers), {'ok': True})
        request('/api/permissions', headers=web_headers, expected=401)
        request('/api/status', headers=web_headers, expected=401)
        request('/api/pairing/leave', {}, web_headers, expected=401)

    def test_pairing_read_rechecks_revocation_before_reply(self):
        with tempfile.TemporaryDirectory() as folder:
            store = pairing.Store(Path(folder) / 'pairing.sqlite')
            self.server.pairing = store
            device = str(uuid.uuid4())
            store.register({'deviceId': device, 'deviceToken': 'a' * 64})
            for path in ('/api/console', '/api/relay/keys', '/api/relay/usage?id=test', '/api/relay/usage?id=test&refresh=1'):
                token = store.complete({'code': store.code(device)['code']})['token']
                screen = store.permissions(device, token)['screenId']

                def revoked_reply(*args, **kwargs):
                    store.kick(device, {'id': screen})
                    return {'private': 'should not be returned'}

                method = 'command' if 'refresh=1' in path else 'read'
                with patch.object(store, method, side_effect=revoked_reply):
                    with self.assertRaises(HTTPError) as error:
                        urlopen(Request(self.url + path, headers={'X-Pairing-Token': token}))
                    self.assertEqual(error.exception.code, 401, path)
            store.close()


if __name__ == '__main__':
    unittest.main()
