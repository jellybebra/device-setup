"""Routing priority regressions; no changes to the installed client."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('updater', Path(__file__).with_name('update-v2rayn-zapret.py'))
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class GeneralWebRouting(unittest.TestCase):
    def setUp(self):
        self.rules = [
            {'Id': 'broad-domain', 'Domain': ['geosite:ru-blocked'], 'OutboundTag': 'proxy'},
            {'Id': 'vpn', 'Domain': ['domain:challenges.cloudflare.com', 'geosite:openai'], 'OutboundTag': 'proxy'},
            {'Id': 'private', 'Ip': ['geoip:private'], 'OutboundTag': 'direct', 'Enabled': True},
            {'Id': 'broad-ip', 'Ip': ['geoip:ru-blocked'], 'OutboundTag': 'proxy'},
            {'Id': 'tunnel', 'Port': '7844', 'Network': 'tcp,udp', 'OutboundTag': 'proxy'},
            {'Id': 'default', 'Port': '0-65535', 'OutboundTag': 'direct'},
        ]

    def test_explicit_exceptions_precede_general_web_and_broad_blocklists(self):
        result = updater.general_web_rules(self.rules, 'zapret')
        self.assertEqual([r['Id'] for r in result[:3]], ['vpn', 'private', 'tunnel'])
        self.assertEqual([r['Id'] for r in result[-3:]], ['broad-domain', 'broad-ip', 'default'])
        for original in self.rules:
            self.assertEqual(next(r for r in result if r['Id'] == original['Id']), original)
        quic, web = result[3:5]
        self.assertEqual((quic['Network'], quic['Port'], quic['OutboundTag']), ('udp', '443', 'block'))
        self.assertEqual((web['Network'], web['Port'], web['OutboundTag']),
                         ('tcp', '80,443,2053,2083,2087,2096,8443', 'zapret'))

    def test_second_update_is_identical(self):
        once = updater.general_web_rules(self.rules, 'zapret')
        self.assertEqual(once, updater.general_web_rules(once, 'zapret'))

    def test_requires_unconditional_enabled_private_network_exception(self):
        for change in ({'Enabled': False}, {'Network': 'udp'}, {'Port': '80'}, {'OutboundTag': 'proxy'}):
            rules = [dict(r) for r in self.rules]
            rules[2].update(change)
            with self.assertRaises(ValueError):
                updater.general_web_rules(rules, 'zapret')

    def test_mixed_custom_rule_is_preserved_as_exception(self):
        custom = {'Id': 'custom', 'Domain': ['geosite:ru-blocked', 'domain:example.com'], 'OutboundTag': 'proxy'}
        result = updater.general_web_rules([custom] + self.rules, 'zapret')
        self.assertEqual(result[0], custom)

    def test_runtime_maps_only_zapret_tag_and_skips_disabled_rules(self):
        saved = updater.general_web_rules(self.rules, 'zapret')
        saved.append({'Id': 'disabled', 'Enabled': False, 'OutboundTag': 'block'})
        runtime = updater.runtime_rules(saved, 'zapret', 'runtime-zapret')
        self.assertEqual(len(runtime), len(saved) - 1)
        self.assertEqual(runtime[0]['outboundTag'], 'proxy')
        self.assertEqual(runtime[4]['outboundTag'], 'runtime-zapret')
        self.assertTrue(all(r['type'] == 'field' and 'id' not in r and 'remarks' not in r for r in runtime))


if __name__ == '__main__':
    unittest.main()
