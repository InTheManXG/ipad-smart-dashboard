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
                    patch.object(bridge, 'execute_control', return_value=True) as execute, \
                    patch.object(bridge, 'send', side_effect=OSError('ack lost')), \
                    patch.object(bridge.time, 'sleep', side_effect=[None, RuntimeError('stop test')]):
                with self.assertRaisesRegex(RuntimeError, 'stop test'):
                    bridge.main()
                execute.assert_called_once()

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
                self.assertEqual(json.load(response), {'ok': True})

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
