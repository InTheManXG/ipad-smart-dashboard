import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import relay
import test_server


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.patch = patch.object(relay, 'DATA', Path(self.directory.name))
        self.patch.start()
        relay.CACHE.clear()

    def tearDown(self):
        self.patch.stop()
        self.directory.cleanup()

    def test_keys_persist_edit_delete_and_validation(self):
        relay.change_key({'action': 'save', 'name': '公司一', 'key': 'test-secret'})
        relay.change_key({'action': 'save', 'name': '公司二', 'key': 'second-secret'})
        items = relay.public_keys()
        self.assertEqual(len(items), 2)
        self.assertNotIn('secret', json.dumps(items))
        identity = items[0]['id']
        relay.change_key({'action': 'save', 'id': identity, 'name': '改名', 'key': ''})
        self.assertEqual(relay.read_keys()[0]['key'], 'test-secret')
        self.assertEqual((relay.DATA / 'keys.json').stat().st_mode & 0o777, 0o600)
        for value in [{'action': 'save', 'name': '', 'key': 'x'}, {'action': 'save', 'name': 'x', 'key': 'a\nb'}, {'action': 'delete', 'id': 'missing'}, {'action': 'save', 'id': [], 'name': 'x', 'key': 'x'}]:
            with self.assertRaises(ValueError):
                relay.change_key(value)
        self.assertEqual(len(relay.public_keys()), 2)
        relay.change_key({'action': 'delete', 'id': identity})
        self.assertEqual(len(relay.public_keys()), 1)

    def test_usage_whitelist_cache_and_failure(self):
        relay.change_key({'action': 'save', 'name': '公司', 'key': 'test-secret'})
        identity = relay.public_keys()[0]['id']
        payload = {'isValid': True, 'remaining': 176.24, 'unit': 'USD', 'key': 'test-secret', 'subscription': {'daily_limit_usd': 300, 'daily_usage_usd': 123.76}, 'usage': {'today': {'cost': 0}}}
        opener = Mock()
        opener.open.return_value = io.BytesIO(json.dumps(payload).encode())
        with patch('relay.build_opener', return_value=opener):
            result = relay.read_usage(identity)
            self.assertEqual(result['dailyUsed'], 123.76)
            self.assertEqual(result['remaining'], 176.24)
            self.assertNotIn('secret', json.dumps(result))
            self.assertEqual(relay.read_usage(identity), result)
            self.assertEqual(opener.open.call_count, 1)
            opener.open.return_value = io.BytesIO(json.dumps(payload).encode())
            self.assertEqual(relay.read_usage(identity, force=True)['remaining'], 176.24)
            self.assertEqual(opener.open.call_count, 2)
        relay.change_key({'action': 'save', 'id': identity, 'name': '公司', 'key': 'replacement'})
        opener.open.side_effect = HTTPError('url', 401, 'test-secret', {}, None)
        with patch('relay.build_opener', return_value=opener):
            result = relay.read_usage(identity)
            self.assertIn('error', result)
            self.assertNotIn('remaining', result)
            self.assertNotIn('secret', json.dumps(result))
        self.assertIsNone(relay.number(float('nan')))
        self.assertIsNone(relay.number(True))
        self.assertIsNone(relay.number(10 ** 400))
        self.assertIsNone(relay.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.com'))


class RelayHTTPTests(unittest.TestCase):
    setUp = test_server.ServerTests.setUp
    tearDown = test_server.ServerTests.tearDown

    def test_relay_authentication_and_storage(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(relay, 'DATA', Path(directory)):
            for path in ['/api/relay/keys', '/api/relay/usage?id=x', '/.relay-data/keys.json']:
                with self.assertRaises(HTTPError) as error:
                    urlopen(self.url + path)
                self.assertIn(error.exception.code, (401, 404))
            data = json.dumps({'action': 'save', 'name': '公司', 'key': 'test-secret'}).encode()
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + '/api/relay/keys', data=data))
            self.assertEqual(error.exception.code, 401)
            headers = {'X-Display-Token': 'test-only'}
            with urlopen(Request(self.url + '/api/relay/keys', data=data, headers=headers)) as response:
                self.assertTrue(json.load(response)['ok'])
            with urlopen(Request(self.url + '/api/relay/keys', headers=headers)) as response:
                result = response.read().decode()
                self.assertIn('公司', result)
                self.assertNotIn('secret', result)

    def test_manual_refresh_forwarded(self):
        with patch('server.relay.read_usage', return_value={'remaining': 12}) as read:
            request = Request(self.url + '/api/relay/usage?id=test&refresh=1',
                              headers={'X-Display-Token': 'test-only'})
            with urlopen(request) as response:
                self.assertEqual(json.load(response)['remaining'], 12)
            read.assert_called_once_with('test', force=True)
