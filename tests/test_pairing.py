import tempfile
import uuid
import unittest
from pathlib import Path

import pairing


class PairingStoreTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
