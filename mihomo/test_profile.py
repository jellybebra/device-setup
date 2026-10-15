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

    def test_wireguard_provider_preserves_keys_addresses_and_psk(self):
        path = self.root / 'provider.conf'
        path.write_text('[Interface]\nPrivateKey=private\nAddress=10.2.0.2/32,fd00::2/128\n'
                        'DNS=10.2.0.1\nMTU=1320\n[Peer]\nPublicKey=public\n'
                        'PresharedKey=psk\nAllowedIPs=0.0.0.0/0,::/0\n'
                        'Endpoint=[2001:db8::1]:51820\nPersistentKeepalive=20\n')
        node = profile.wireguard(path, 'Proton')
        self.assertEqual((node['private-key'], node['public-key'], node['pre-shared-key']),
                         ('private', 'public', 'psk'))
        self.assertEqual((node['ip'], node['ipv6'], node['server'], node['mtu']),
                         ('10.2.0.2', 'fd00::2', '2001:db8::1', 1320))

    def test_provider_rejects_hooks_and_non_internet_routes(self):
        base = '[Interface]\nPrivateKey=private\nAddress=10.0.0.2/32\n{}[Peer]\nPublicKey=public\nAllowedIPs={}\nEndpoint=example.com:51820\n'
        path = self.root / 'provider.conf'
        for hook, allowed in [('PostUp=do-something\n', '0.0.0.0/0'), ('', '10.0.0.0/24')]:
            with self.subTest(hook=hook, allowed=allowed):
                path.write_text(base.format(hook, allowed))
                with self.assertRaises(ValueError):
                    profile.wireguard(path, 'Provider')

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
