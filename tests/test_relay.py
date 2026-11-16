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
        self.station('https://relay.example.test')

    def station(self, url):
        (relay.DATA / 'station.json').write_text(json.dumps({'type': 'sub2api', 'url': url}))

    def tearDown(self):
        self.patch.stop()
        self.directory.cleanup()

    def test_keys_persist_edit_delete_and_validation(self):
        relay.change_key({'action': 'save', 'name': '公司一', 'key': 'test-secret'})
        relay.change_key({'action': 'save', 'name': '公司二', 'key': 'second-secret'})
        items = relay.public_keys()
        self.assertEqual(len(items), 2)
        self.assertNotIn('secret', json.dumps(items))
        self.assertEqual(items[0]['maskedKey'], 'te****cret')
        self.assertNotIn('key', items[0])
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

    def test_short_keys_are_fully_masked(self):
        for key in ['a', 'abcdef']:
            relay.change_key({'action': 'save', 'name': '短 Key', 'key': key})
        self.assertTrue(all(item['maskedKey'] == '****' for item in relay.public_keys()))

    def test_usage_whitelist_cache_and_failure(self):
        relay.change_key({'action': 'save', 'name': '公司', 'key': 'test-secret'})
        identity = relay.public_keys()[0]['id']
        payload = {'isValid': True, 'remaining': 176.24, 'unit': 'USD', 'key': 'test-secret', 'subscription': {'daily_limit_usd': 300, 'daily_usage_usd': 123.76}, 'usage': {'today': {'cost': 0}}}
        opener = Mock()
        opener.open.return_value = io.BytesIO(json.dumps(payload).encode())
        with patch('relay.build_opener', return_value=opener):
            result = relay.read_usage(identity)
            request = opener.open.call_args.args[0]
            self.assertEqual(request.full_url, 'https://relay.example.test/v1/usage')
            self.assertEqual(request.get_header('Authorization'), 'Bearer test-secret')
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

    def test_usage_requires_configured_https_station(self):
        relay.change_key({'action': 'save', 'name': '测试', 'key': 'test-secret'})
        identity = relay.public_keys()[0]['id']
        (relay.DATA / 'station.json').unlink()
        with patch('relay.build_opener') as opener:
            with self.assertRaises(ValueError):
                relay.read_usage(identity)
            for url in ('http://localhost', 'http://relay.example.test', 'https://user:pass@relay.example.test',
                        'https://relay.example.test/other', 'https://relay.example.test?token=secret',
                        'https://relay.example.test#fragment', 'https://relay.example.test:70000',
                        'https://relay.example.test/a/../v1', 'https://relay.example.test\\@other.test', ''):
                self.station(url)
                with self.assertRaises(ValueError, msg=url):
                    relay.read_usage(identity)
            for invalid in ({'type': 'other', 'url': 'https://relay.example.test'}, [], {'type': 'sub2api'}):
                (relay.DATA / 'station.json').write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    relay.read_usage(identity)
            opener.assert_not_called()
        for url in ('https://relay.example.test', 'https://relay.example.test/', 'https://relay.example.test/v1', 'https://relay.example.test/v1/'):
            self.station(url)
            self.assertEqual(relay.usage_url(), 'https://relay.example.test/v1/usage')

    def test_usage_cache_and_inflight_reply_follow_station(self):
        relay.change_key({'action': 'save', 'name': '测试', 'key': 'test-secret'})
        identity = relay.public_keys()[0]['id']
        payload = {'isValid': True, 'remaining': 10, 'unit': 'USD'}
        opener = Mock()
        opener.open.side_effect = lambda *args, **kwargs: io.BytesIO(json.dumps(payload).encode())
        with patch('relay.build_opener', return_value=opener):
            relay.read_usage(identity)
            self.station('https://another.example.test/v1')
            relay.read_usage(identity)
            self.assertEqual(opener.open.call_count, 2, '站点切换不能复用旧缓存')
            self.assertEqual(opener.open.call_args.args[0].full_url, 'https://another.example.test/v1/usage')

            def change_station(*args, **kwargs):
                self.station('https://third.example.test')
                return io.BytesIO(json.dumps(payload).encode())

            opener.open.side_effect = change_station
            with self.assertRaises(ValueError):
                relay.read_usage(identity, force=True)
            self.assertEqual(relay.CACHE[identity][0][0], 'https://another.example.test/v1/usage')


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

    def test_usage_without_station_is_rejected_before_request(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(relay, 'DATA', Path(directory)), patch('relay.build_opener') as opener:
            relay.change_key({'action': 'save', 'name': '测试', 'key': 'test-secret'})
            identity = relay.public_keys()[0]['id']
            request = Request(self.url + '/api/relay/usage?id=' + identity, headers={'X-Display-Token': 'test-only'})
            with self.assertRaises(HTTPError) as error:
                urlopen(request)
            self.assertEqual(error.exception.code, 400)
            opener.assert_not_called()
