import unittest
from build_profile import connection_choices, VPN_GROUP, VLESS_NODE


class ConnectionChoicesTest(unittest.TestCase):
    def test_both_ingress_addresses_preserve_identity_and_tls(self):
        source = {'name': 'old', 'type': 'vless', 'server': 'example.com',
                  'servername': 'cover.example.com', 'uuid': 'test-id',
                  'reality-opts': {'public-key': 'test-public-key'},
                  'dialer-proxy': 'obsolete-selector'}
        nodes, groups = connection_choices(source)
        self.assertEqual([n['server'] for n in nodes], ['92.246.139.113', '138.124.114.237'])
        self.assertEqual(groups, [{'name': VPN_GROUP, 'type': 'select',
                                  'proxies': [n['name'] for n in nodes]}])
        self.assertEqual(nodes[0]['name'], VLESS_NODE)
        for node in nodes:
            self.assertNotIn('dialer-proxy', node)
            for key in ['servername', 'uuid', 'reality-opts']:
                self.assertEqual(node[key], source[key])
        self.assertEqual(source['server'], 'example.com')
        self.assertIn('dialer-proxy', source)

    def test_missing_sni_and_duplicate_addresses_are_rejected(self):
        with self.assertRaises(ValueError):
            connection_choices({'type': 'vless'})
        with self.assertRaises(ValueError):
            connection_choices({'type': 'vless', 'servername': 'example.com'},
                               primary='192.0.2.1', alternate='192.0.2.1')
