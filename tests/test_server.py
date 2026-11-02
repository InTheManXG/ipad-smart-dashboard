import json
import threading
import unittest
from unittest.mock import patch
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from http.server import ThreadingHTTPServer
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


if __name__ == '__main__':
    unittest.main()
