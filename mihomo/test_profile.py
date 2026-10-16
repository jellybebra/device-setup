import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('profile', Path(__file__).with_name('build_profile.py'))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_policy_preserves_precedence_and_default(self):
        path = self.root / 'rules.json'
        path.write_text(json.dumps([
            {'domain': ['full:cdn.example.com'], 'outboundTag': 'direct'},
            {'domain': ['domain:example.com'], 'outboundTag': 'proxy'},
            {'port': '0-65535', 'outboundTag': 'direct'}]))
        self.assertEqual(profile.routes(path), ['DOMAIN,cdn.example.com,DIRECT',
                         'DOMAIN-SUFFIX,example.com,VPN', 'MATCH,DIRECT'])

    def test_combined_condition_is_not_silently_broadened(self):
        path = self.root / 'rules.json'
        path.write_text(json.dumps([{'domain': ['domain:example.com'], 'port': '443',
                                    'outboundTag': 'proxy'}]))
        with self.assertRaises(ValueError):
            profile.routes(path)


if __name__ == '__main__':
    unittest.main()
