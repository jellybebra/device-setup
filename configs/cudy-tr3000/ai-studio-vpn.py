"""Apply the AI Studio route on Cudy using the local quiet provider profile."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


DOMAINS = (
    'ai.studio',
    'aistudio.google.com',
    'accounts.google.com',
    'waa-pa.clients6.google.com',
    'generativelanguage.googleapis.com',
    'alkalimakersuite-pa.clients6.google.com',
    'webchannel-alkalimakersuite-pa.clients6.google.com',
    'alkalimakersuiteapplets.pa.clients6.google.com',
)


def settings():
    chain = json.loads(Path('/etc/vpn-chain/chain.json').read_text())
    outbound = next(n['outbound'] for n in chain['nodes'] if n['name'] == 'quiet')
    stream = outbound['streamSettings']
    tls = stream['tlsSettings']
    if (outbound['protocol'] != 'vless' or stream['security'] != 'tls'
            or stream['network'] not in ('raw', 'tcp') or tls.get('allowInsecure')):
        raise ValueError('Expected the quiet VLESS/TLS profile')
    server, = outbound['settings']['vnext']
    user, = server['users']
    flow = user['flow']
    if flow == 'xtls-rprx-vision':
        flow = 'xtls-rprx-vision-udp443'
    node = {
        'remarks': 'AI Studio Finland', 'type': 'Xray', 'protocol': 'vless',
        'address': server['address'], 'port': str(server['port']), 'uuid': user['id'],
        'encryption': user['encryption'], 'flow': flow, 'transport': 'raw',
        'tls': '1', 'tls_serverName': tls['serverName'], 'utls': '1',
        'fingerprint': tls['fingerprint'], 'alpn': ','.join(tls['alpn']),
    }
    rule = {
        'remarks': 'Google AI Studio', 'group': 'Custom', 'network': 'tcp,udp',
        'domain_list': '\n'.join(f'domain:{d}' for d in DOMAINS),
    }
    return {
        'ai_studio_fi': 'nodes', **{f'ai_studio_fi.{k}': v for k, v in node.items()},
        'AIStudio': 'shunt_rules', **{f'AIStudio.{k}': v for k, v in rule.items()},
        'split.AIStudio': 'ai_studio_fi',
        # Give these domains distinct destinations even when Google shares an
        # address with a service cached in PassWall2's direct nftables set.
        'split.fakedns': '1',
        'split.AIStudio_fakedns': '1',
    }


def current(key):
    result = subprocess.run(['uci', '-q', 'get', 'passwall2.' + key],
                            capture_output=True, text=True)
    return result.stdout.rstrip('\n') if result.returncode == 0 else None


def main():
    if current('main.node') != 'split' or current('split.protocol') != '_shunt':
        raise SystemExit('Expected active split routing')
    if subprocess.check_output(['uci', 'changes', 'passwall2']).strip():
        raise SystemExit('Apply or revert pending PassWall2 changes first')
    changes = {k: v for k, v in settings().items() if current(k) != v}
    if not changes:
        print('AI Studio route already configured.')
        return
    config = Path('/etc/config/passwall2')
    backup = Path(tempfile.mkdtemp(prefix='aistudio-backup.', dir='/root')) / config.name
    shutil.copy2(config, backup)
    print(f'Backup: {backup}', flush=True)
    try:
        for key, value in changes.items():
            # Keep profile values out of exception tracebacks.
            if subprocess.run(['uci', 'set', f'passwall2.{key}={value}']).returncode:
                raise RuntimeError(f'Could not set {key}')
        subprocess.run(['uci', 'commit', 'passwall2'], check=True)
        for service in ('passwall2', 'dnsmasq'):
            subprocess.run([f'/etc/init.d/{service}', 'restart'], check=True)
    except BaseException:
        subprocess.run(['uci', 'revert', 'passwall2'], check=False)
        shutil.copy2(backup, config)
        for service in ('passwall2', 'dnsmasq'):
            subprocess.run([f'/etc/init.d/{service}', 'restart'], check=False)
        raise


if __name__ == '__main__':
    main()
