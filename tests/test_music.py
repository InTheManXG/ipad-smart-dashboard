import importlib.util
import json
from pathlib import Path
import unittest
import threading
import time
import tempfile
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import music
import test_server

spec = importlib.util.spec_from_file_location('music_bridge', Path(__file__).resolve().parents[1] / 'music/bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def snapshot():
    return {'state': 'ready', 'trackId': 'a' * 64, 'title': '测试歌曲', 'artist': '歌手', 'source': '网易云音乐',
            'playing': True, 'position': 10, 'duration': 120, 'lyricsState': 'ready',
            'lines': [{'time': 0, 'text': '第一句'}, {'time': 20, 'text': '第二句'}]}


class MusicTests(unittest.TestCase):
    def test_track_identity_survives_netease_seek(self):
        metadata = {'bundleIdentifier': 'com.netease.163music', 'title': '歌曲', 'artist': '歌手',
                    'album': '专辑', 'duration': 200, 'elapsedTimeNow': 90, 'playing': True, 'contentItemIdentifier': 'before'}
        with patch.object(bridge.subprocess, 'check_output', side_effect=[json.dumps(metadata).encode(),
                json.dumps(metadata | {'elapsedTimeNow': 0, 'contentItemIdentifier': 'after'}).encode(),
                json.dumps(metadata | {'title': '另一首歌'}).encode()]):
            before, after, other = bridge.read_player(), bridge.read_player(), bridge.read_player()
        self.assertEqual(before['trackId'], after['trackId'])
        self.assertNotEqual(before['trackId'], other['trackId'])

    def test_lost_ack_does_not_repeat_native_command(self):
        command = {'requestId': 'test-request', 'trackId': 'a' * 64, 'action': 'next', 'expiresIn': 8}
        with tempfile.TemporaryDirectory() as folder:
            token = Path(folder) / 'token'
            token.write_text('test-only')
            with patch('sys.argv', ['bridge.py', '--url', 'http://127.0.0.1:18088', '--token-file', str(token)]), \
                    patch.object(bridge, 'read_player', return_value=snapshot() | {'album': '测试专辑'}), \
                    patch.object(bridge, 'find_lyrics', return_value=[]), \
                    patch.object(bridge, 'publish', return_value=(command, time.monotonic())), \
                    patch.object(bridge, 'execute_control', return_value=snapshot()) as execute, \
                    patch.object(bridge, 'send', side_effect=OSError('ack lost')), \
                    patch.object(bridge.time, 'sleep', side_effect=[None, RuntimeError('stop test')]):
                with self.assertRaisesRegex(RuntimeError, 'stop test'):
                    bridge.main()
                execute.assert_called_once()

    def test_fast_site_control_does_not_wait_for_slow_site(self):
        command = {'requestId': 'fast-request', 'trackId': 'a' * 64, 'action': 'pause', 'expiresIn': 8}
        slow_finished = threading.Event()
        executed = threading.Event()
        order = []

        def publish(url, token, value):
            if url.endswith(':18088'):
                executed.wait(.5)
                slow_finished.set()
                return None, time.monotonic()
            return command, time.monotonic()

        def execute(*args):
            order.append(slow_finished.is_set())
            executed.set()
            return snapshot()

        with tempfile.TemporaryDirectory() as folder:
            token = Path(folder) / 'token'
            token.write_text('test-only')
            with patch('sys.argv', ['bridge.py', '--url', 'http://127.0.0.1:18088',
                                   '--url', 'https://example.test', '--token-file', str(token)]), \
                    patch.object(bridge, 'read_player', return_value=snapshot() | {'album': '测试专辑'}) as read, \
                    patch.object(bridge, 'find_lyrics', return_value=[]), \
                    patch.object(bridge, 'publish', side_effect=publish), \
                    patch.object(bridge, 'execute_control', side_effect=execute), \
                    patch.object(bridge, 'send', return_value={}), \
                    patch.object(bridge.time, 'sleep', side_effect=RuntimeError('stop test')) as sleep:
                with self.assertRaisesRegex(RuntimeError, 'stop test'):
                    bridge.main()
                self.assertEqual(order, [False])
                read.assert_called_once()
                self.assertGreaterEqual(sleep.call_args.args[0], 0)
                self.assertLessEqual(sleep.call_args.args[0], .25)

    def test_upload_reuses_connection_and_reconnects_without_retry(self):
        with patch.dict(bridge._connections, {}, clear=True), \
                patch.object(bridge.http.client, 'HTTPSConnection') as factory:
            connection = factory.return_value
            response = connection.getresponse.return_value.__enter__.return_value
            response.status = 200
            response.read.return_value = b'{"ok":true}'
            for _ in range(2):
                self.assertTrue(bridge.send('https://example.test/api/music', 'test-only', snapshot())['ok'])
            factory.assert_called_once()
            self.assertEqual(connection.request.call_count, 2)
            connection.request.side_effect = bridge.http.client.RemoteDisconnected('closed')
            with self.assertRaises(OSError):
                bridge.send('https://example.test/api/music', 'test-only', snapshot())
            self.assertEqual(connection.request.call_count, 3, '断线不能立即重发操作')
            connection.close.assert_called_once()
            connection.request.side_effect = None
            bridge.send('https://example.test/api/music', 'test-only', snapshot())
            self.assertEqual(factory.call_count, 2)

    def test_waiting_upload_wakes_when_control_arrives(self):
        music.put(snapshot())
        waiting = threading.Event()
        original_wait = music._control_condition.wait
        received, results = [], []

        def wait(timeout=None):
            waiting.set()
            return original_wait(timeout)

        with patch.object(music._control_condition, 'wait', side_effect=wait):
            listener = threading.Thread(target=lambda: received.append(music.pending_control(wait=2)))
            listener.start()
            self.assertTrue(waiting.wait(1))
            worker = threading.Thread(target=lambda: results.append(music.control(
                {'action': 'pause', 'trackId': 'a' * 64})))
            worker.start()
            try:
                listener.join(.5)
                self.assertFalse(listener.is_alive(), '新指令必须唤醒上报，不能等满轮询超时')
                self.assertEqual(received[0]['action'], 'pause')
            finally:
                pending = music.pending_control()
                if pending:
                    music.acknowledge({'requestId': pending['requestId'], 'ok': True})
                worker.join(1)
                listener.join(2)
        self.assertTrue(results[0]['ok'])

    def test_command_ack_busy_expiry_and_changed_track(self):
        music.put(snapshot())
        value = {'action': 'next', 'trackId': 'a' * 64}
        result = []
        worker = threading.Thread(target=lambda: result.append(music.control(value)))
        worker.start()
        try:
            for _ in range(100):
                command = music.pending_control()
                if command:
                    break
                time.sleep(.005)
            self.assertIsNotNone(command)
            self.assertEqual(music.control(value)['error'], 'unavailable')
            music.acknowledge({'requestId': 'wrong-id', 'ok': True})
            self.assertIsNotNone(music.pending_control())
            music.acknowledge({'requestId': command['requestId'], 'ok': True})
        finally:
            if music.pending_control():
                music.acknowledge({'requestId': music.pending_control()['requestId'], 'ok': False})
            worker.join(1)
        self.assertEqual(result, [{'ok': True, 'error': None}])
        self.assertIsNone(music.pending_control())
        with patch.object(music._control_condition, 'wait_for', return_value=False):
            self.assertEqual(music.control(value)['error'], 'unconfirmed')
        self.assertIsNone(music.pending_control())
        self.assertFalse(music.control(value | {'trackId': 'b' * 64})['ok'])
        music.put({'state': 'idle'})
        self.assertFalse(music.control(value)['ok'])
        with self.assertRaises(ValueError):
            music.control(value | {'action': 'rm -rf /'})

    def test_mac_commands_validate_target_and_verify_result(self):
        command = {'requestId': 'test', 'trackId': 'a' * 64, 'action': 'pause', 'expiresIn': 8}
        with patch.object(bridge, 'read_player', side_effect=[snapshot(), snapshot() | {'playing': False}]), patch.object(bridge.subprocess, 'run') as run:
            self.assertTrue(bridge.execute_control(command, time.monotonic()))
            self.assertEqual(run.call_args.args[0], [bridge.MEDIA_CONTROL, 'pause'])
        for action, args, result in [('next', ['next-track'], snapshot() | {'trackId': 'b' * 64}),
                                     ('previous', ['previous-track'], snapshot() | {'trackId': 'b' * 64}),
                                     ('play', ['play'], snapshot())]:
            with patch.object(bridge, 'read_player', side_effect=[snapshot(), result]), patch.object(bridge.subprocess, 'run') as run:
                self.assertTrue(bridge.execute_control(command | {'action': action}, time.monotonic()))
                self.assertEqual(run.call_args.args[0], [bridge.MEDIA_CONTROL, *args])
        with patch.object(bridge, 'read_player', side_effect=[snapshot(), snapshot(), snapshot() | {'position': 0}]), patch.object(bridge.subprocess, 'run') as run:
            self.assertTrue(bridge.execute_control(command | {'action': 'replay'}, time.monotonic()))
            self.assertEqual([call.args[0] for call in run.call_args_list], [[bridge.MEDIA_CONTROL, 'seek', '0'], [bridge.MEDIA_CONTROL, 'play']])
        with patch.object(bridge, 'read_player', return_value=snapshot() | {'trackId': 'b' * 64}), patch.object(bridge.subprocess, 'run') as run:
            self.assertFalse(bridge.execute_control(command, time.monotonic()))
            run.assert_not_called()
        with patch.object(bridge, 'read_player', return_value=snapshot()), patch.object(bridge.subprocess, 'run') as run:
            self.assertFalse(bridge.execute_control(command, time.monotonic() - 9))
            self.assertFalse(bridge.execute_control(command | {'action': 'shell'}, time.monotonic()))
            run.assert_not_called()

    def test_lrc_timestamps_offset_and_instrumental(self):
        self.assertEqual(bridge.parse_lrc('[offset:500]\n[00:01.25][01:02.003]同一句\n[00:03.00]\n[ar:作者]'),
                         [{'time': .75, 'text': '同一句'}, {'time': 2.5, 'text': ''}, {'time': 61.503, 'text': '同一句'}])
        self.assertEqual(bridge.parse_lrc('没有时间轴'), [])
        self.assertEqual(bridge.parse_lrc('[00:01]原文\n[00:01]译文')[0]['text'], '原文 / 译文')

    def test_matching_rejects_cover_and_wrong_duration(self):
        track = snapshot()
        songs = [{'id': 1, 'name': '测试歌曲', 'artists': [{'name': '翻唱者'}], 'duration': 120000},
                 {'id': 2, 'name': '测试歌曲', 'artists': [{'name': '歌手'}], 'duration': 200000},
                 {'id': 3, 'name': '测试歌曲', 'artists': [{'name': '歌手'}], 'duration': 120000}]
        with patch.object(bridge, 'fetch', side_effect=[{'result': {'songs': songs}}, {'lrc': {'lyric': '[00:01]正确歌词'}}]) as fetch:
            self.assertEqual(bridge.find_lyrics(track)[0]['text'], '正确歌词')
            self.assertEqual(fetch.call_args.args[1]['id'], 3)
        with patch.object(bridge, 'fetch', return_value={'result': {'songs': songs[:2]}}) as fetch:
            self.assertEqual(bridge.find_lyrics(track), [])
            self.assertEqual(fetch.call_count, 1)

    def test_verified_old_release_uses_exact_id_without_matching_other_versions(self):
        track = snapshot() | {'title': '梦醒时分', 'artist': '周冰倩', 'album': '梦醒时分', 'duration': 244.333}
        with patch.object(bridge, 'fetch', return_value={'lrc': {'lyric': '[00:01]测试歌词'}}) as fetch:
            self.assertEqual(bridge.find_lyrics(track)[0]['text'], '测试歌词')
            fetch.assert_called_once_with('song/lyric', {'id': 334909, 'lv': -1, 'kv': -1, 'tv': -1})
        for change in ({'artist': '其他歌手'}, {'album': '其他专辑'}, {'duration': 238.421}):
            with patch.object(bridge, 'fetch', return_value={'result': {'songs': []}}) as fetch:
                self.assertEqual(bridge.find_lyrics(track | change), [])
                self.assertEqual(fetch.call_args.args[0], 'search/get')

    def test_play_pause_and_stale_snapshot(self):
        with patch('music.time.monotonic', return_value=100):
            music.put(snapshot())
        with patch('music.time.monotonic', return_value=102):
            self.assertEqual(music.get()['position'], 12)
        with patch('music.time.monotonic', return_value=109):
            self.assertEqual(music.get(), {'state': 'offline'})
        paused = snapshot() | {'playing': False}
        music.put(paused)
        self.assertEqual(music.get()['position'], 10)
        music.put({'state': 'idle'})
        self.assertNotIn('lines', music.get())

    def test_validation(self):
        for change in ({'position': float('nan')}, {'duration': float('inf')}, {'playing': 1},
                       {'lines': [{'time': -1, 'text': 'bad'}]}, {'title': 'x' * 301},
                       {'lines': [{'time': 2, 'text': 'a'}, {'time': 1, 'text': 'b'}]}):
            with self.assertRaises(ValueError):
                music.validate(snapshot() | change)
        self.assertNotIn('private', music.validate(snapshot() | {'private': 'secret'}))


class MusicHTTPTests(unittest.TestCase):
    setUp = test_server.ServerTests.setUp
    tearDown = test_server.ServerTests.tearDown

    def test_control_and_ack_authentication(self):
        for endpoint in ('control', 'ack'):
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + '/api/music/' + endpoint, data=b'{}'))
            self.assertEqual(error.exception.code, 401)
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + '/api/music/' + endpoint, data=b'{}', headers={'X-Display-Token': 'test-only'}))
            self.assertEqual(error.exception.code, 400)
        with patch('music.control', return_value={'ok': True}):
            with urlopen(Request(self.url + '/api/music/control', data=b'{}', headers={'X-Display-Token': 'test-only'})) as response:
                result = json.load(response)
                self.assertTrue(result['ok'])
                self.assertIn('snapshot', result)

    def test_snapshot_upload_ack_returns_confirmed_state(self):
        music.put(snapshot())
        headers = {'X-Display-Token': 'test-only'}
        results = []

        def control():
            request = Request(self.url + '/api/music/control', headers=headers,
                              data=json.dumps({'action': 'pause', 'trackId': 'a' * 64}).encode())
            with urlopen(request, timeout=10) as response:
                results.append(json.load(response))

        worker = threading.Thread(target=control)
        worker.start()
        try:
            for _ in range(100):
                command = music.pending_control()
                if command:
                    break
                time.sleep(.005)
            self.assertIsNotNone(command)
            updated = snapshot() | {'playing': False, 'position': 13,
                                    'ack': {'requestId': command['requestId'], 'ok': True}}
            with urlopen(Request(self.url + '/api/music', headers=headers,
                                 data=json.dumps(updated).encode())) as response:
                self.assertEqual(response.status, 200)
        finally:
            if music.pending_control():
                music.acknowledge({'requestId': music.pending_control()['requestId'], 'ok': False})
            worker.join(2)
        self.assertEqual(len(results), 1)
        self.assertTrue(results[0]['ok'])
        self.assertFalse(results[0]['snapshot']['playing'])
        self.assertEqual(results[0]['snapshot']['position'], 13)
        self.assertNotIn('ack', results[0]['snapshot'])

    def test_music_auth_and_validation(self):
        for data in (None, json.dumps(snapshot()).encode()):
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + '/api/music', data=data))
            self.assertEqual(error.exception.code, 401)
        headers = {'X-Display-Token': 'test-only'}
        with urlopen(Request(self.url + '/api/music', data=json.dumps(snapshot()).encode(), headers=headers)) as response:
            self.assertEqual(response.status, 200)
        with urlopen(Request(self.url + '/api/music', headers=headers)) as response:
            self.assertEqual(json.load(response)['title'], '测试歌曲')
        for value in ([], {'state': 'ready'}, snapshot() | {'lines': None}):
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + '/api/music', data=json.dumps(value).encode(), headers=headers))
            self.assertEqual(error.exception.code, 400)
