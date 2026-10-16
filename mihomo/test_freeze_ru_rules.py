import json
from pathlib import Path
import tempfile
import unittest

from freeze_ru_rules import export, fields, isolate


def vi(n):
    result = bytearray()
    while n >= 128:
        result.append((n & 127) | 128)
        n >>= 7
    return bytes(result + bytes([n]))


def field(n, value):
    return vi(n << 3 | 2) + vi(len(value)) + value


class FrozenRulesTests(unittest.TestCase):
    def test_routing_order_and_no_resolve_survive(self):
        profile = {'rules': ['GEOSITE,google,DIRECT', 'GEOIP,ru-blocked,VPN,no-resolve',
                             'GEOSITE,ru-blocked,VPN', 'MATCH,DIRECT']}
        isolate(profile)
        self.assertEqual(profile['rules'], ['GEOSITE,google,DIRECT',
                         'RULE-SET,device-setup-ru-blocked-ip,VPN,no-resolve',
                         'RULE-SET,device-setup-ru-blocked-domain,VPN', 'MATCH,DIRECT'])
        self.assertEqual(profile['rule-providers']['device-setup-ru-blocked-ip']['behavior'], 'ipcidr')
        self.assertEqual(isolate(profile), profile)

    def test_full_and_suffix_domains_and_ipv6(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            ip4 = field(1, bytes([192, 0, 2, 0])) + b'\x10\x18'
            ip6 = field(1, bytes.fromhex('20010db8000000000000000000000000')) + b'\x10\x20'
            (root/'geoip.dat').write_bytes(field(1, field(1, b'RU-BLOCKED') + field(2, ip4) + field(2, ip6)))
            suffix = b'\x08\x02' + field(2, b'example.org')
            full = b'\x08\x03' + field(2, b'only.example.net')
            (root/'geosite.dat').write_bytes(field(1, field(1, b'ru-blocked') + field(2, suffix) + field(2, full)))
            result = export(root, root/'output')
            self.assertEqual(result['ip']['count'], 2)
            def payload(name):
                return [json.loads(line.strip()[2:]) for line in (root/'output'/name).read_text().splitlines()[1:]]
            self.assertEqual(payload('ru-blocked-ip.yaml'),
                             ['192.0.2.0/24', '2001:db8::/32'])
            self.assertEqual(payload('ru-blocked-domain.yaml'),
                             ['+.example.org', 'only.example.net'])
            (root/'geosite.dat').write_bytes(field(1, field(1, b'ru-blocked') + field(2, b'\x08\x01' + field(2, b'.*'))))
            with self.assertRaises(ValueError):
                export(root, root/'bad-output')
            self.assertFalse((root/'bad-output').exists())

    def test_truncated_data_fails_closed(self):
        for data in [b'\x0a\x05ab', b'\x80', b'\x00']:
            with self.assertRaises(ValueError):
                list(fields(data))


if __name__ == '__main__':
    unittest.main()
