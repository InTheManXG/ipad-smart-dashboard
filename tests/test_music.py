import json
import unittest
import threading
import time
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import music
import test_server


def snapshot():
    return {'state': 'ready', 'trackId': 'a' * 64, 'title': '测试歌曲', 'artist': '歌手', 'source': '网易云音乐',
            'playing': True, 'position': 10, 'duration': 120, 'lyricsState': 'ready',
            'lines': [{'time': 0, 'text': '第一句'}, {'time': 20, 'text': '第二句'}]}


class MusicTests(unittest.TestCase):
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
    def test_play_pause_and_stale_snapshot(self):
        with patch('music.time.monotonic', return_value=100):
            music.put(snapshot())
        with patch('music.time.monotonic', return_value=102):
            self.assertEqual(music.get()['position'], 12)
        with patch('music.time.monotonic', return_value=109):
            self.assertEqual(music.get(), {'state': 'offline', 'layout': 'standard'})
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

    def test_layout_is_validated_for_every_state(self):
        for state in ('ready', 'idle', 'unavailable', 'offline'):
            value = snapshot() | {'state': state}
            self.assertEqual(music.validate(value)['layout'], 'standard', '旧版本快照默认标准布局')
            for layout in ('standard', 'priority', 'full'):
                with self.subTest(state=state, layout=layout):
                    self.assertEqual(music.validate(value | {'layout': layout})['layout'], layout)
            for invalid in (None, True, 1, [], {}, '', 'unknown', ' full'):
                with self.subTest(state=state, invalid=invalid), self.assertRaises(ValueError):
                    music.validate(value | {'layout': invalid})

    def test_stale_snapshot_keeps_layout_without_song(self):
        for layout in ('standard', 'priority', 'full'):
            for enabled in (False, True):
                with patch('music.time.monotonic', return_value=100):
                    music.put(snapshot() | {'enabled': enabled, 'layout': layout})
                with patch('music.time.monotonic', return_value=109):
                    self.assertEqual(music.get(), {'state': 'offline', 'enabled': enabled, 'layout': layout})


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
