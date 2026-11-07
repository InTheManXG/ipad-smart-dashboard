import tempfile
import threading
import time
import uuid
import unittest
from pathlib import Path

import pairing


class PairingStoreTests(unittest.TestCase):
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
