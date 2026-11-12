import base64
import sqlite3
import tempfile
import threading
import time
import uuid
import unittest
from pathlib import Path

import pairing


class PairingStoreTests(unittest.TestCase):
    def test_retina_icon_size_boundary(self):
        item = {'id': str(uuid.uuid4()), 'name': '高清应用', 'kind': 'app', 'state': 'idle'}
        # 使用边界大小验证传输限制，PNG 像素及真实解码由原生测试覆盖。
        raw = b'\x89PNG\r\n\x1a\n' + bytes(40000 - 8)
        icon = 'data:image/png;base64,' + base64.b64encode(raw).decode()
        self.assertEqual(pairing.clean_console([item | {'icon': icon}])[0]['icon'], icon)
        for oversized in (icon + 'AAAA', 'data:image/png;base64,' + base64.b64encode(raw + b'x').decode()):
            with self.assertRaises(pairing.Failure):
                pairing.clean_console([item | {'icon': oversized}])

    def test_waiting_exchange_wakes_on_open_and_preserves_parallel_music(self):
        with tempfile.TemporaryDirectory() as folder:
            store = pairing.Store(Path(folder) / 'pairing.sqlite')
            ident, target = str(uuid.uuid4()), str(uuid.uuid4())
            store.register({'deviceId': ident, 'deviceToken': 'a' * 64})
            token = store.complete({'code': store.code(ident)['code']})['token']
            status = {'conversations': [{'threadId': target, 'title': '测试', 'state': 'running'}]}
            waiting, delivered = threading.Event(), threading.Event()
            responses, results = [], []
            original_wait = store.condition.wait_for
            def observed_wait(predicate, timeout=None):
                if timeout == .8: waiting.set()
                return original_wait(predicate, timeout)
            store.condition.wait_for = observed_wait
            def exchange():
                responses.append(store.exchange(ident, {'status': status, 'waitForCommand': True}))
                delivered.set()
            uploader = threading.Thread(target=exchange)
            uploader.start()
            self.assertTrue(waiting.wait(1))
            # 等待指令不能锁住其他上传，也不能在醒来后覆盖较新的音乐快照。
            store.exchange(ident, {'music': {'state': 'idle', 'enabled': False}})
            started = time.monotonic()
            caller = threading.Thread(target=lambda: results.append(store.command(
                ident, {'threadId': target}, 'open', token, wait=2)))
            caller.start()
            self.assertTrue(delivered.wait(.6), '点击必须唤醒等待请求，而非等满轮询周期')
            self.assertLess(time.monotonic() - started, .6)
            uploader.join(1)
            command = responses[0]['commands'][0]
            self.assertEqual(command['threadId'], target)
            self.assertEqual(store.exchange(ident, {'status': status})['commands'], [])
            store.exchange(ident, {'acks': [{'requestId': command['requestId'], 'ok': True}]})
            caller.join(2)
            self.assertEqual(results, [{'ok': True}])
            self.assertFalse(store.read(ident, 'music')['enabled'])
            # 没有新指令时有界返回；旧客户端不指定等待时仍立即返回。
            started = time.monotonic()
            self.assertEqual(store.exchange(ident, {'status': status, 'waitForCommand': True})['commands'], [])
            self.assertLess(time.monotonic() - started, 1.5)
            started = time.monotonic()
            store.exchange(ident, {'status': status})
            self.assertLess(time.monotonic() - started, .2)
            store.close()

    def test_subscription_console_item(self):
        item = {'id': str(uuid.uuid4()), 'name': '更新订阅', 'kind': 'subscription', 'state': 'idle', 'target': 'all'}
        result = pairing.clean_console([item])
        self.assertEqual(result[0]['kind'], 'subscription')
        self.assertNotIn('target', result[0])

    def test_console_private_fields_routing_and_freshness(self):
        with tempfile.TemporaryDirectory() as folder:
            store = pairing.Store(Path(folder) / 'pairing.sqlite')
            ident = str(uuid.uuid4())
            store.register({'deviceId': ident, 'deviceToken': 'a' * 64})
            token = store.complete({'code': store.code(ident)['code']})['token']
            item = {'id': str(uuid.uuid4()), 'name': '测试脚本', 'kind': 'script', 'state': 'idle', 'target': '/private/test.sh', 'output': 'secret'}
            store.exchange(ident, {'status': {}, 'console': [item]})
            self.assertEqual(set(store.read(ident, 'console')[0]), {'id', 'name', 'kind', 'state', 'icon'})
            with self.assertRaises(pairing.Failure): store.command(ident, {'id': item['id'], 'target': 'injected'}, 'console', token)
            with self.assertRaises(pairing.Failure): store.command(ident, {'id': str(uuid.uuid4())}, 'console', token)
            result = []
            worker = threading.Thread(target=lambda: result.append(store.command(ident, {'id': item['id']}, 'console', token, wait=2)))
            worker.start()
            deadline = time.monotonic() + 2
            while not store.pending.get(ident) and time.monotonic() < deadline: time.sleep(.01)
            self.assertEqual(store.exchange(ident, {'music': {'state': 'idle'}})['commands'], [])
            commands = store.exchange(ident, {'status': {}})['commands']
            self.assertEqual(commands[0]['id'], item['id'])
            self.assertNotIn('target', commands[0])
            self.assertEqual(store.exchange(ident, {'status': {}})['commands'], [], '在途指令不能重复下发')
            store.exchange(ident, {'acks': [{'requestId': commands[0]['requestId'], 'ok': True}], 'console': [item | {'state': 'running'}]})
            worker.join(3); self.assertEqual(result, [{'ok': True}])
            with self.assertRaises(pairing.Failure): store.command(ident, {'id': item['id']}, 'console', token)
            snapshot = store.snapshots[ident]
            store.snapshots[ident] = snapshot[:5] + (time.monotonic() - 60,)
            store.exchange(ident, {'music': {'state': 'idle'}})
            with self.assertRaises(pairing.Failure): store.read(ident, 'console')
            for invalid in [[item | {'icon': 'https://bad.test/icon'}], [item | {'icon': 'data:image/png;base64,AAAA'}], [item, item], [item | {'kind': 'arbitrary'}], [item | {'name': ''}]]:
                with self.assertRaises(pairing.Failure): pairing.clean_console(invalid)
            store.close()

    def test_kick_only_owned_screen_and_cancel_pending(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'pairing.sqlite'
            store = pairing.Store(path)
            ident, other = str(uuid.uuid4()), str(uuid.uuid4())
            store.register({'deviceId': ident, 'deviceToken': 'a' * 64})
            store.register({'deviceId': other, 'deviceToken': 'b' * 64})
            first = store.complete({'code': store.code(ident)['code']}, 'first')['token']
            second = store.complete({'code': store.code(ident)['code']}, 'second')['token']
            screen = next(s for s in store.screens(ident)['screens'] if s['ua'] == 'first')
            with self.assertRaises(pairing.Failure): store.kick(other, {'id': screen['id']})
            self.assertEqual(store.authenticate(first, 'web'), ident)
            key = str(uuid.uuid4())
            store.exchange(ident, {'status': {}, 'keys': [{'id': key, 'name': '测试'}]})
            errors = []
            def query():
                try: store.command(ident, {'id': key}, 'usage', first, wait=2)
                except pairing.Failure as error: errors.append(error.message)
            worker = threading.Thread(target=query); worker.start()
            deadline = time.monotonic() + 2
            while not store.pending.get(ident) and time.monotonic() < deadline: time.sleep(.01)
            command = store.exchange(ident, {'status': {}})['commands'][0]
            store.kick(ident, {'id': screen['id']})
            store.exchange(ident, {'acks': [{'requestId': command['requestId'], 'ok': True, 'usage': {'remaining': 12}}]})
            worker.join(3)
            self.assertFalse(worker.is_alive())
            self.assertTrue(errors, '撤销后晚到的成功回执不能恢复访问')
            self.assertEqual(len(store.screens(ident)['screens']), 1)
            self.assertEqual(store.authenticate(second, 'web'), ident)
            with self.assertRaises(pairing.Failure): store.authenticate(first, 'web')
            store.close(); store = pairing.Store(path)
            with self.assertRaises(pairing.Failure): store.authenticate(first, 'web')
            self.assertEqual(store.authenticate(second, 'web'), ident)
            fresh = store.complete({'code': store.code(ident)['code']}, 'first')['token']
            self.assertNotEqual(first, fresh)
            self.assertEqual(store.authenticate(fresh, 'web'), ident)
            store.close()

    def test_multiple_screens_remarks_ua_and_legacy_sessions(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'pairing.sqlite'
            store = pairing.Store(path)
            first, other = str(uuid.uuid4()), str(uuid.uuid4())
            store.register({'deviceId': first, 'deviceToken': 'a' * 64})
            store.register({'deviceId': other, 'deviceToken': 'b' * 64})
            web1 = store.complete({'code': store.code(first)['code']}, 'iPad Safari')['token']
            web2 = store.complete({'code': store.code(first)['code']}, 'Chrome Desktop')['token']
            self.assertEqual(store.authenticate(web1, 'web'), first)
            self.assertEqual(store.authenticate(web2, 'web'), first)
            screens = store.screens(first)['screens']
            self.assertEqual(len(screens), 2)
            self.assertEqual({s['ua'] for s in screens}, {'iPad Safari', 'Chrome Desktop'})
            screen = next(s for s in screens if s['ua'] == 'iPad Safari')
            self.assertNotIn('secret', screen)
            self.assertNotIn('token', screen)
            store.remark(first, {'id': screen['id'], 'remark': '办公室'})
            with self.assertRaises(pairing.Failure):
                store.remark(other, {'id': screen['id'], 'remark': '越权'})
            with self.assertRaises(pairing.Failure):
                store.remark(first, {'id': screen['id'], 'remark': 'x' * 81})
            store.close()
            store = pairing.Store(path)
            store.authenticate(web1, 'web', 'Updated Safari')
            changed = next(s for s in store.screens(first)['screens'] if s['id'] == screen['id'])
            self.assertEqual((changed['remark'], changed['ua']), ('办公室', 'Updated Safari'))
            # 模拟升级前只有 sessions 记录的旧网页，不要求重新配对。
            legacy = 'c' * 64
            store.db.execute('INSERT INTO sessions VALUES(?,?,?)', (pairing.digest(legacy), first, time.time()+100))
            store.db.commit()
            self.assertEqual(store.authenticate(legacy, 'web', 'Legacy UA'), first)
            self.assertEqual(len(store.screens(first)['screens']), 3)
            store.leave(web2)
            self.assertEqual(len(store.screens(first)['screens']), 2)
            self.assertEqual(store.db.execute('SELECT COUNT(*) FROM screens WHERE secret=?', (pairing.digest(web2),)).fetchone()[0], 0)
            store.close()

    def test_two_web_screens_can_queue_usage_queries(self):
        with tempfile.TemporaryDirectory() as folder:
            store = pairing.Store(Path(folder) / 'pairing.sqlite')
            ident = str(uuid.uuid4())
            store.register({'deviceId': ident, 'deviceToken': 'a' * 64})
            tokens = [store.complete({'code': store.code(ident)['code']})['token'] for _ in range(2)]
            key = str(uuid.uuid4())
            store.exchange(ident, {'status': {}, 'keys': [{'id': key, 'name': '测试'}]})
            results, errors = [], []
            def query(token):
                try: results.append(store.command(ident, {'id': key}, 'usage', token, wait=2))
                except Exception as exc: errors.append(exc)
            workers = [threading.Thread(target=query, args=(token,)) for token in tokens]
            for worker in workers: worker.start()
            deadline = time.monotonic() + 4
            while any(w.is_alive() for w in workers) and time.monotonic() < deadline:
                response = store.exchange(ident, {'status': {}})
                for command in response['commands']:
                    store.exchange(ident, {'acks': [{'requestId': command['requestId'], 'ok': True, 'usage': {'remaining': 12}}]})
                time.sleep(.01)
            for worker in workers: worker.join(3)
            self.assertEqual(errors, [])
            self.assertEqual(results, [{'remaining': 12}, {'remaining': 12}])
            store.close()

    def test_music_enabled_survives_exchange_and_disconnect(self):
        with tempfile.TemporaryDirectory() as folder:
            store = pairing.Store(Path(folder) / 'pairing.sqlite')
            ident = str(uuid.uuid4())
            store.register({'deviceId': ident, 'deviceToken': 'a' * 64})
            for enabled in (False, True, False):
                store.exchange(ident, {'music': {'state': 'offline', 'enabled': enabled}})
                self.assertEqual(store.read(ident, 'music')['enabled'], enabled)
                store.exchange(ident, {'status': {}})
                self.assertEqual(store.read(ident, 'music')['enabled'], enabled)
                item = store.snapshots[ident]
                store.snapshots[ident] = (time.monotonic() - 100,) + item[1:]
                self.assertEqual(store.read(ident, 'music')['enabled'], enabled)
            with self.assertRaises(ValueError):
                store.exchange(ident, {'music': {'state': 'offline', 'enabled': 'false'}})
            store.close()

    def test_code_binds_browser_to_one_device(self):
        with tempfile.TemporaryDirectory() as folder:
            store = pairing.Store(Path(folder) / 'pairing.sqlite')
            device_id = str(uuid.uuid4())
            device_token = 'a' * 64
            self.assertFalse(store.register({'deviceId': device_id, 'deviceToken': device_token, 'name': '测试 Mac'})['paired'])
            code = store.code(device_id)['code']
            session = store.complete({'code': code})['token']
            self.assertEqual(store.authenticate(session, 'web'), device_id)
            with self.assertRaises(pairing.Failure):
                store.complete({'code': code})
            store.close()

    def test_snapshot_and_music_are_isolated(self):
        with tempfile.TemporaryDirectory() as folder:
            store = pairing.Store(Path(folder) / 'pairing.sqlite')
            first, second = str(uuid.uuid4()), str(uuid.uuid4())
            for device_id in (first, second):
                store.register({'deviceId': device_id, 'deviceToken': device_id.replace('-', '') * 2, 'name': device_id})
            status = {'schema': 1, 'state': 'running', 'conversations': [], 'conversationsAvailable': True, 'quotaAvailable': True}
            store.exchange(first, {'status': status, 'music': {'state': 'idle'}, 'keys': []})
            self.assertEqual(store.read(first, 'status')['state'], 'running')
            with self.assertRaises(pairing.Failure):
                store.read(second, 'status')
            store.close()

    def test_command_only_delivered_to_matching_uploader(self):
        with tempfile.TemporaryDirectory() as folder:
            store = pairing.Store(Path(folder) / 'pairing.sqlite')
            ident = str(uuid.uuid4())
            store.register({'deviceId': ident, 'deviceToken': 'a' * 64})
            token = store.complete({'code': store.code(ident)['code']})['token']
            key = str(uuid.uuid4())
            store.exchange(ident, {'status': {}, 'keys': [{'id': key, 'name': '测试'}]})
            result = []
            worker = threading.Thread(target=lambda: result.append(store.command(ident, {'id': key}, 'usage', token)))
            worker.start()
            try:
                deadline = time.monotonic() + 2
                while not store.pending.get(ident) and time.monotonic() < deadline: time.sleep(.01)
                self.assertEqual(store.exchange(ident, {'music': {'state': 'idle'}})['commands'], [])
                command = store.exchange(ident, {'status': {}})['commands'][0]
                self.assertEqual(command['kind'], 'usage')
                store.exchange(ident, {'acks': [{'requestId': command['requestId'], 'ok': True, 'usage': {'remaining': 12}}]})
                worker.join(2)
                self.assertEqual(result, [{'remaining': 12}])
            finally:
                worker.join(9)
                store.close()


if __name__ == '__main__':
    unittest.main()
