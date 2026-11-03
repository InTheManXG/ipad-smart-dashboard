import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import music
import test_server

spec = importlib.util.spec_from_file_location('music_bridge', Path(__file__).resolve().parents[1] / 'music/bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def snapshot():
    return {'state': 'ready', 'title': '测试歌曲', 'artist': '歌手', 'source': '网易云音乐',
            'playing': True, 'position': 10, 'duration': 120, 'lyricsState': 'ready',
            'lines': [{'time': 0, 'text': '第一句'}, {'time': 20, 'text': '第二句'}]}


class MusicTests(unittest.TestCase):
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
