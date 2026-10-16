import copy
import json
from pathlib import Path
import tempfile
import unittest

from build_profile import vless_from_xray


class VlessImportTest(unittest.TestCase):
    def setUp(self):
        self.source = {'outbounds': [{
            'tag': 'proxy', 'protocol': 'vless',
            'settings': {'vnext': [{'address': 'example.com', 'port': 443, 'users': [{
                'id': '00000000-0000-4000-8000-000000000001',
                'encryption': 'none', 'flow': 'xtls-rprx-vision'}]}]},
            'streamSettings': {'network': 'raw', 'security': 'reality', 'realitySettings': {
                'serverName': 'example.com', 'publicKey': 'test-public-key',
                'shortId': 'abcd', 'fingerprint': 'firefox'}}}]}

    def convert(self, source):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'source.json'
            path.write_text(json.dumps(source), encoding='utf-8')
            return vless_from_xray(path)

    def test_preserves_reality_and_udp_without_importing_system_settings(self):
        self.source['inbounds'] = [{'protocol': 'tun'}]
        self.source['routing'] = {'rules': [{'outboundTag': 'block'}]}
        node = self.convert(self.source)
        self.assertEqual(node['client-fingerprint'], 'firefox')
        self.assertEqual(node['flow'], 'xtls-rprx-vision')
        self.assertEqual(node['packet-encoding'], 'xudp')
        self.assertTrue(node['udp'])
        self.assertNotIn('dialer-proxy', node)
        self.assertNotIn('skip-cert-verify', node)
        self.assertNotIn('inbounds', node)
        self.assertNotIn('routing', node)

    def test_refuses_transport_or_security_downgrade(self):
        for field, value in [('network', 'ws'), ('security', 'none')]:
            with self.subTest(field=field):
                source = copy.deepcopy(self.source)
                source['outbounds'][0]['streamSettings'][field] = value
                with self.assertRaises(ValueError):
                    self.convert(source)

    def test_refuses_silently_dropping_chaining_and_extra_verification(self):
        for setting in ['proxySettings', 'mldsa65Verify']:
            with self.subTest(setting=setting):
                source = copy.deepcopy(self.source)
                if setting == 'proxySettings':
                    source['outbounds'][0][setting] = {'tag': 'another-hop'}
                else:
                    source['outbounds'][0]['streamSettings']['realitySettings'][setting] = 'required-key'
                with self.assertRaises(ValueError):
                    self.convert(source)

    def test_refuses_ambiguous_outbound(self):
        self.source['outbounds'] *= 2
        with self.assertRaises(ValueError):
            self.convert(self.source)


if __name__ == '__main__':
    unittest.main()
