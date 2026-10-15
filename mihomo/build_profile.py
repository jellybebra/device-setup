"""Build a private Mihomo profile from separate provider credentials and routing policy.

Output is JSON, which is also valid YAML; use a .yaml extension for GUI import.
The output directory must already exist with private filesystem permissions.
"""
import argparse
import configparser
import ipaddress
import json
from pathlib import Path
import secrets


def wireguard(path, name, mtu=None):
    conf = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=('#', ';'))
    conf.read_string(Path(path).read_text(encoding='utf-8-sig'))
    if set(conf.sections()) != {'Interface', 'Peer'}:
        raise ValueError('Expected one Interface and one Peer')
    iface, peer = conf['Interface'], conf['Peer']
    if set(iface) - {'address', 'privatekey', 'dns', 'mtu', 'listenport'}:
        raise ValueError('Unsupported Interface fields; hooks are not imported')
    if set(peer) - {'publickey', 'presharedkey', 'allowedips', 'endpoint', 'persistentkeepalive'}:
        raise ValueError('Unsupported Peer fields')
    host, port = peer['endpoint'].rsplit(':', 1)
    node = {'name': name, 'type': 'wireguard', 'server': host.strip('[]'),
            'port': int(port), 'private-key': iface['privatekey'],
            'public-key': peer['publickey'], 'udp': True,
            'mtu': mtu or iface.getint('mtu', 1280)}
    # These profiles provide a full Internet exit; routing is managed by Mihomo.
    allowed = {str(ipaddress.ip_network(x.strip())) for x in peer['allowedips'].split(',')}
    if '0.0.0.0/0' not in allowed:
        raise ValueError('Provider must support a full IPv4 Internet exit')
    for address in iface['address'].split(','):
        ip = ipaddress.ip_interface(address.strip()).ip
        node['ip' if ip.version == 4 else 'ipv6'] = str(ip)
    if 'ip' not in node:
        raise ValueError('Provider needs an IPv4 address')
    if peer.get('presharedkey'):
        node['pre-shared-key'] = peer['presharedkey']
    node['persistent-keepalive'] = peer.getint('persistentkeepalive', 25)
    return node


def routes(path):
    """Translate this repository's Windows policy; fail on unsupported semantics."""
    result = []
    mapping = {'direct': 'DIRECT', 'proxy': 'VPN', 'block': 'REJECT'}
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
    account = json.loads(Path(args.warp_account).read_text(encoding='utf-8-sig'))
    warp = {'name': 'WARP', 'type': 'masque', 'server': args.warp_endpoint, 'port': 443,
            'private-key': account['private_key'],
            'public-key': ''.join(x for x in account['endpoint_pub_key'].splitlines()
                                  if not x.startswith('-----')),
            'ip': account['ipv4'], 'mtu': 1280, 'udp': True,
            'sni': 'consumer-masque.cloudflareclient.com'}
    own = wireguard(args.wireguard, 'My server', mtu=1280)
    own['dialer-proxy'] = 'Server transport'
    nodes = [own, warp]
    if args.proton:
        nodes.append(wireguard(args.proton, 'Proton'))
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
                'nameserver': ['https://1.1.1.1/dns-query#VPN'],
                'direct-nameserver': ['https://1.1.1.1/dns-query#DIRECT'],
                'proxy-server-nameserver': ['https://1.1.1.1/dns-query#DIRECT']},
        'proxies': nodes,
        'proxy-groups': [
            {'name': 'VPN', 'type': 'select', 'proxies': [node['name'] for node in nodes]},
            {'name': 'Server transport', 'type': 'select', 'proxies': ['WARP', 'DIRECT']}],
        'rules': routes(args.rules),
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--warp-account', required=True)
    parser.add_argument('--wireguard', required=True)
    parser.add_argument('--proton', help='Optional Proton WireGuard .conf')
    parser.add_argument('--rules', default=str(Path(__file__).resolve().parents[1] / 'configs/v2rayn/windows/routes.json'))
    parser.add_argument('--interface', default='Ethernet')
    parser.add_argument('--warp-endpoint', default='162.159.198.2')
    parser.add_argument('--port', type=int, default=19606)
    parser.add_argument('--dns-port', type=int, default=19653)
    parser.add_argument('--controller-port', type=int, default=19690)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    target = Path(args.output)
    if not target.parent.is_dir():
        parser.error('Create a private output directory first')
    if target.exists():
        parser.error('Refusing to overwrite an existing profile')
    profile = build(args)
    with target.open('x', encoding='utf-8') as output:
        json.dump(profile, output, indent=2, ensure_ascii=False)
    print(f'Profile written: {target}; TUN disabled; {len(profile["rules"])} routing rules')
