import unittest
from build_profile import connection_choices, VPN_GROUP, VLESS_NODE, WG_NODE, VLESS_PATH, WG_PATH, DIRECT_NODE


class ConnectionChoicesTest(unittest.TestCase):
    def test_all_paths_terminate_without_cycles_and_defaults_keep_vless_direct(self):
        nodes, groups = connection_choices(
            {'name': 'old-wg', 'type': 'wireguard'},
            {'name': 'old-warp', 'type': 'masque'},
            {'name': 'old-vless', 'type': 'vless'})
        by_name = {n['name']: n for n in nodes + groups}
        self.assertEqual(by_name[VPN_GROUP]['proxies'][0], VLESS_NODE)
        self.assertNotIn(DIRECT_NODE, by_name[VPN_GROUP]['proxies'])
        # WARP must resolve the VLESS hostname without using default DNS,
        # which itself travels through the selected VLESS/WARP chain.
        self.assertTrue(by_name['WARP']['remote-dns-resolve'])
        self.assertEqual(by_name['WARP']['dns'], ['https://1.1.1.1/dns-query'])
        self.assertNotIn('dialer-proxy', by_name['WARP'])
        for node, group in [(VLESS_NODE, VLESS_PATH), (WG_NODE, WG_PATH)]:
            self.assertEqual(by_name[node]['dialer-proxy'], group)
            self.assertEqual(by_name[group]['proxies'], [DIRECT_NODE, 'WARP'])

        def walk(name, path):
            self.assertNotIn(name, path, 'Connection graph contains a cycle')
            node = by_name[name]
            children = node.get('proxies', [])
            if 'dialer-proxy' in node:
                children = [node['dialer-proxy']]
            for child in children:
                walk(child, path + [name])
        walk(VPN_GROUP, [])

    def test_without_vless_no_dangling_selector_and_proton_is_independent(self):
        nodes, groups = connection_choices(
            {'type': 'wireguard'}, {'type': 'masque'},
            proton={'name': 'Proton', 'type': 'wireguard'})
        self.assertEqual([g['name'] for g in groups], [VPN_GROUP, WG_PATH])
        self.assertIn('Proton', groups[0]['proxies'])
        self.assertNotIn('dialer-proxy', next(n for n in nodes if n['name'] == 'Proton'))
