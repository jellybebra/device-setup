"""Build a private Mihomo profile from separate provider credentials and routing policy.

Output is JSON, which is also valid YAML; use a .yaml extension for GUI import.
The output directory must already exist with private filesystem permissions.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import secrets
import uuid
from urllib.parse import quote

VPN_GROUP = 'VPN — выход в интернет'
VLESS_NODE = 'Мой сервер · VLESS'
ALTERNATE_NODE = 'Мой сервер · VLESS · 138.124.114.237'


def connection_choices(vless, primary='92.246.139.113', alternate='138.124.114.237'):
    """Two direct ingress addresses of the same server, preserving Reality SNI."""
    if vless.get('type') != 'vless' or not vless.get('servername'):
        raise ValueError('Expected a VLESS Reality node with explicit TLS server name')
    primary = str(ipaddress.IPv4Address(primary))
    alternate = str(ipaddress.IPv4Address(alternate))
    if primary == alternate:
        raise ValueError('Primary and alternate ingress addresses must differ')
    base = {k: v for k, v in vless.items() if k != 'dialer-proxy'}
    alternate_name = ALTERNATE_NODE if alternate == '138.124.114.237' else f'Мой сервер · VLESS · {alternate}'
    nodes = [dict(base, name=VLESS_NODE, server=primary),
             dict(base, name=alternate_name, server=alternate)]
    return nodes, [{'name': VPN_GROUP, 'type': 'select',
                    'proxies': [node['name'] for node in nodes]}]


def vless_from_xray(path, name='My server (VLESS)', tag='proxy'):
    """Import the raw/TCP Reality outbound, never Xray's routing or listeners."""
    config = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    matches = [node for node in config.get('outbounds', []) if node.get('tag') == tag]
    if len(matches) != 1 or matches[0].get('protocol') != 'vless':
        raise ValueError('Expected one VLESS outbound with the requested tag')
    source = matches[0]
    if source.get('proxySettings') or source.get('mux', {}).get('enabled'):
        raise ValueError('Chained or multiplexed Xray outbounds need manual conversion')
    stream = source.get('streamSettings', {})
    if stream.get('network', 'tcp') not in ('tcp', 'raw') or stream.get('security') != 'reality':
        raise ValueError('Only VLESS TCP/raw with Reality is supported')
    if any(value for key, value in stream.items()
           if key not in ('network', 'security', 'realitySettings')):
        raise ValueError('Additional transport/socket settings need manual conversion')
    servers = source.get('settings', {}).get('vnext', [])
    if len(servers) != 1 or len(servers[0].get('users', [])) != 1:
        raise ValueError('Expected one VLESS server and user')
    server, user = servers[0], servers[0]['users'][0]
    if user.get('encryption', 'none') != 'none' or user.get('flow', '') not in ('', 'xtls-rprx-vision'):
        raise ValueError('Unsupported VLESS encryption or flow')
    reality = stream.get('realitySettings', {})
    if reality.get('mldsa65Verify'):
        raise ValueError('Post-quantum Reality verification needs manual conversion')
    if not reality.get('publicKey') or not reality.get('serverName'):
        raise ValueError('Reality public key and server name are required')
    node = {
        'name': name, 'type': 'vless', 'server': server['address'], 'port': int(server['port']),
        'uuid': str(uuid.UUID(user['id'])), 'network': 'tcp', 'tls': True,
        'servername': reality['serverName'], 'client-fingerprint': reality.get('fingerprint') or 'chrome',
        'reality-opts': {'public-key': reality['publicKey'], 'short-id': reality.get('shortId', '')},
        'udp': True, 'packet-encoding': 'xudp',
    }
    if user.get('flow'):
        node['flow'] = user['flow']
    return node


def routes(path, vpn_group='VPN'):
    """Translate this repository's Windows policy; fail on unsupported semantics."""
    result = []
    mapping = {'direct': 'DIRECT', 'proxy': vpn_group, 'block': 'REJECT'}
    for rule in json.loads(Path(path).read_text(encoding='utf-8-sig')):
        if not rule.get('enabled', True):
            continue
        if set(rule) - {'domain', 'ip', 'process', 'port', 'network', 'protocol',
                        'outboundTag', 'enabled', 'remarks'}:
            raise ValueError('Unknown routing fields')
        target = mapping[rule['outboundTag']]
        kinds = set(rule) & {'domain', 'ip', 'process', 'port', 'protocol'}
        if len(kinds) != 1 or rule.get('network', 'tcp,udp') != 'tcp,udp':
            raise ValueError('Unsupported combined routing condition')
        if 'domain' in rule:
            for domain in rule['domain']:
                prefix, value = domain.split(':', 1)
                kind = {'domain': 'DOMAIN-SUFFIX', 'full': 'DOMAIN',
                        'geosite': 'GEOSITE', 'regexp': 'DOMAIN-REGEX'}[prefix]
                if ',' in value:
                    raise ValueError('Comma in domain expression needs manual conversion')
                result.append(f'{kind},{value},{target}')
        elif 'ip' in rule:
            for network in rule['ip']:
                if network.startswith('geoip:'):
                    result.append(f'GEOIP,{network[6:]},{target},no-resolve')
                else:
                    parsed = ipaddress.ip_network(network)
                    result.append(f'IP-CIDR{"6" if parsed.version == 6 else ""},{parsed},{target},no-resolve')
        elif 'process' in rule:
            result.extend(f'PROCESS-NAME,{name},{target}' for name in rule['process'])
        elif 'protocol' in rule:
            if rule['protocol'] != ['bittorrent'] or target != 'DIRECT':
                raise ValueError('Unsupported application protocol rule')
            # Mihomo has no equivalent BitTorrent protocol matcher. Explicitly
            # cover common clients; unknown programs use the final DIRECT rule.
            result.extend(f'PROCESS-NAME,{name},DIRECT' for name in
                          ('qbittorrent.exe', 'uTorrent.exe', 'Transmission-qt.exe'))
        elif rule['port'] == '0-65535':
            result.append(f'MATCH,{target}')
        elif rule['port'].isdigit():
            result.append(f'DST-PORT,{rule["port"]},{target}')
        else:
            raise ValueError('Unsupported port range')
    if not result or result[-1] != 'MATCH,DIRECT':
        raise ValueError('Expected direct access as the default policy')
    return result


def build(args):
    vless = vless_from_xray(args.vless_xray_config)
    nodes, groups = connection_choices(vless, args.primary_ip, args.alternate_ip)
    return {
        'mixed-port': args.port, 'allow-lan': False, 'bind-address': '127.0.0.1',
        'mode': 'rule', 'log-level': 'warning', 'ipv6': False,
        'interface-name': args.interface, 'find-process-mode': 'strict',
        'external-controller': f'127.0.0.1:{args.controller_port}',
        'secret': secrets.token_urlsafe(32), 'profile': {'store-selected': True},
        'geodata-mode': True, 'geo-auto-update': False,
        'geox-url': {name: f'https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/{name}.dat'
                    for name in ('geoip', 'geosite')},
        'tun': {'enable': False, 'stack': 'mixed', 'device': 'mihomo-trial',
                'auto-route': True, 'auto-detect-interface': False,
                'dns-hijack': ['any:53'], 'mtu': 1500},
        'dns': {'enable': True, 'listen': f'127.0.0.1:{args.dns_port}', 'ipv6': False,
                'enhanced-mode': 'fake-ip', 'fake-ip-range': '198.18.0.1/16',
                'fake-ip-filter': ['*.lan', '*.local', 'localhost'],
                'nameserver': ['https://1.1.1.1/dns-query#' + quote(VPN_GROUP, safe='')],
                'direct-nameserver': ['https://1.1.1.1/dns-query#DIRECT'],
                'proxy-server-nameserver': ['https://1.1.1.1/dns-query#DIRECT']},
        'proxies': nodes,
        'proxy-groups': groups,
        'rules': routes(args.rules, VPN_GROUP),
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vless-xray-config', required=True, help='Private Xray config containing the proxy VLESS Reality outbound')
    parser.add_argument('--primary-ip', default='92.246.139.113')
    parser.add_argument('--alternate-ip', default='138.124.114.237')
    parser.add_argument('--rules', default=str(Path(__file__).resolve().parents[1] / 'configs/v2rayn/windows/routes.json'))
    parser.add_argument('--interface', default='Ethernet')
    parser.add_argument('--port', type=int, default=19606)
    parser.add_argument('--dns-port', type=int, default=19653)
    parser.add_argument('--controller-port', type=int, default=19690)
    parser.add_argument('--geodata-dir', type=Path,
                        help='Export ru-blocked from these DAT files to separate local rule providers')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    target = Path(args.output)
    if not target.parent.is_dir():
        parser.error('Create a private output directory first')
    if target.exists():
        parser.error('Refusing to overwrite an existing profile')
    profile = build(args)
    if args.geodata_dir:
        from freeze_ru_rules import export, isolate
        export(args.geodata_dir, target.parent / 'rule-providers' / 'device-setup')
        isolate(profile)
    with target.open('x', encoding='utf-8') as output:
        json.dump(profile, output, indent=2, ensure_ascii=False)
    print(f'Profile written: {target}; TUN disabled; {len(profile["rules"])} routing rules')
    if args.geodata_dir:
        print('For Clash Verge, also copy rule-providers/device-setup into its configuration directory.')
    else:
        print('Warning: ru-blocked depends on custom DAT files. For Clash Verge use --geodata-dir; bundled databases lack this category.')
