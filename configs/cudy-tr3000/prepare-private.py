"""Render credentials outside Git. Does not activate routing or change the PC."""
import argparse
import json
from pathlib import Path


def section(kind, name, values):
    def quote(value):
        return "'" + str(value).replace("'", "'\\''") + "'"
    lines = [f"config {kind} {quote(name)}"]
    for key, value in values.items():
        if isinstance(value, list):
            lines.extend(f"\tlist {key} {quote(v)}" for v in value)
        else:
            lines.append(f"\toption {key} {quote(value)}")
    return "\n".join(lines) + "\n\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, required=True)
    root = parser.parse_args().state_dir
    node = json.loads((root / 'vpn-node.json').read_text())
    params = node['params']
    def param(name, default=''):
        value = params.get(name, default)
        return value[0] if isinstance(value, list) else value

    dns = json.loads((root / 'bootstrap-xray.json').read_text())
    dns['log'] = {'access': 'none', 'loglevel': 'error'}
    dns['inbounds'].append({
        'tag': 'dns-forward', 'listen': '127.0.0.1', 'port': 15353,
        'protocol': 'dokodemo-door',
        'settings': {'address': '1.1.1.1', 'port': 53, 'network': 'tcp,udp'},
    })
    dns['outbounds'][0]['streamSettings']['sockopt'] = {'mark': 255}
    # Accept LAN-side UDP/TCP, but use reliable TCP inside VLESS for upstream
    # DNS. This also preserves non-address query types, unlike A/AAAA-only DNS.
    dns['outbounds'].append({
        'tag': 'dns-tcp', 'protocol': 'dns',
        'settings': {'rewriteNetwork': 'tcp', 'rewriteAddress': '1.1.1.1',
                     'rewritePort': 53, 'rules': [{'action': 'direct'}]},
        'streamSettings': {'sockopt': {'dialerProxy': 'proxy'}},
    })
    dns['routing'] = {'rules': [{'type': 'field', 'inboundTag': ['dns-forward'],
                                'outboundTag': 'dns-tcp'}]}
    (root / 'vpn-dns.json').write_text(json.dumps(dns, indent=2), newline='\n')

    config = section('global', 'main', {
        'enabled': 0, 'node': 'split', 'node_socks_port': 1070,
        'localhost_proxy': 1, 'client_proxy': 1, 'socks_enabled': 0,
        'acl_enable': 0, 'direct_dns_protocol': 'udp',
        'direct_dns': '127.0.0.1:15355', 'direct_dns_query_strategy': 'UseIPv4',
        'remote_dns_protocol': 'doh', 'remote_dns_doh': 'https://1.1.1.1/dns-query',
        'remote_dns_query_strategy': 'UseIPv4', 'remote_fakedns': 0,
        'log_node': 0, 'loglevel': 'warn',
    })
    config += section('global_delay', 'delay', {'start_daemon': 1, 'start_delay': 0})
    config += section('global_forwarding', 'forwarding', {
        'tcp_redir_ports': '1:65535', 'udp_redir_ports': '1:65535',
        'accept_icmp': 0, 'prefer_nft': 1, 'tcp_proxy_way': 'redirect', 'ipv6_tproxy': 0,
    })
    config += section('global_xray', 'xray', {'sniffing_override_dest': 0})
    config += section('global_app', 'apps', {'geoview_file': '/usr/bin/geoview', 'xray_file': '/opt/xray/xray'})
    config += section('global_rules', 'rules', {'geoip_update': 0, 'geosite_update': 0, 'v2ray_location_asset': '/usr/share/v2ray/'})
    config += section('nodes', 'vpn', {
        'remarks': 'VLESS Reality Firefox', 'type': 'Xray', 'protocol': 'vless',
        'address': node['address'], 'port': node['port'], 'uuid': node['uuid'],
        'encryption': param('encryption', 'none'), 'flow': param('flow'),
        'transport': 'raw', 'tcp_guise': 'none', 'tls': 1, 'reality': 1,
        'tls_serverName': param('sni'), 'reality_publicKey': param('pbk'),
        'reality_shortId': param('sid'), 'reality_spiderX': param('spx', '/'),
        'fingerprint': 'firefox', 'utls': 1, 'mux': 0, 'domain_strategy': 'UseIPv4',
    })
    config += section('nodes', 'split', {
        'remarks': 'Direct + zapret2 / selected VPN', 'type': 'Xray', 'protocol': '_shunt',
        'default_node': '_direct', 'domainStrategy': 'IPIfNonMatch', 'domainMatcher': 'hybrid',
        'write_ipset_direct': 1, 'enable_geoview_ip': 1, 'shunt_group': 'Custom',
        'Telegram': 'vpn', 'AI': 'vpn',
    })
    config += section('shunt_rules', 'Telegram', {
        'remarks': 'Telegram including media', 'group': 'Custom', 'network': 'tcp,udp',
        'domain_list': 'geosite:telegram', 'ip_list': 'geoip:telegram',
    })
    config += section('shunt_rules', 'AI', {
        'remarks': 'AI services requiring foreign exit', 'group': 'Custom', 'network': 'tcp,udp',
        'domain_list': '\n'.join('domain:' + d for d in ['openai.com','chatgpt.com','oaistatic.com','oaiusercontent.com','auth0.com','anthropic.com','claude.ai']),
    })
    config += section('shunt_rules', 'VPNFallback', {
        'remarks': 'Manual VPN exceptions', 'group': 'Custom', 'network': 'tcp,udp',
        'domain_list': '# Add only domains that fail tested zapret2 strategies.',
    })
    config += section('shunt_rules', 'Cloudflare', {
        'remarks': 'Cloudflare official IPv4 ranges', 'group': 'Custom',
        'network': 'tcp,udp',
        'ip_list': Path(__file__).with_name('cloudflare-ipv4.txt').read_text().strip(),
    })
    (root / 'passwall2.conf').write_text(config, encoding='utf-8', newline='\n')
    (root / 'vpn-host.txt').write_text(node['address'] + '\n', newline='\n')
    print('Prepared private DNS and PassWall2 configuration; routing remains disabled.')


if __name__ == '__main__':
    main()
