import json
import threading
import unittest
from unittest.mock import patch
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from http.server import ThreadingHTTPServer
from server import Handler, authorized


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

    def test_page(self):
        with urlopen(self.url) as response:
            self.assertIn('任务现场', response.read().decode())


if __name__ == '__main__':
    unittest.main()
