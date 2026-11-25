"""Route AI Studio through the same PassWall2 node as the other AI services."""
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
    'daily-cloudcode-pa.googleapis.com',
    'alkalimakersuite-pa.clients6.google.com',
    'webchannel-alkalimakersuite-pa.clients6.google.com',
    'alkalimakersuiteapplets.pa.clients6.google.com',
)


def settings():
    node = current('split.AI')
    group = current('split.shunt_group')
    if not node or current(f'{node}.protocol') != 'vless' or not group:
        raise SystemExit('Expected a VLESS node for AI and an active shunt group')
    rule = {
        'remarks': 'Google AI Studio', 'group': group, 'network': 'tcp,udp',
        'domain_list': '\n'.join(f'domain:{d}' for d in DOMAINS),
    }
    return {
        'AIStudio': 'shunt_rules', **{f'AIStudio.{k}': v for k, v in rule.items()},
        'split.AIStudio': node,
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
    remove_old_node = False
    if current('ai_studio_fi.remarks') == 'AI Studio Finland':
        # Keep the old node if another PassWall2 setting still references it.
        config_lines = subprocess.check_output(['uci', 'show', 'passwall2'], text=True)
        remove_old_node = not any(
            "'ai_studio_fi'" in line.partition('=')[2].split()
            for line in config_lines.splitlines()
            if not (line.startswith('passwall2.split.AIStudio=') and 'split.AIStudio' in changes)
        )
    if not changes and not remove_old_node:
        print('AI Studio route already configured.')
        return
    config = Path('/etc/config/passwall2')
    backup = Path(tempfile.mkdtemp(prefix='aistudio-backup.', dir='/root')) / config.name
    shutil.copy2(config, backup)
    print(f'Backup: {backup}', flush=True)
    try:
        for key, value in changes.items():
            if subprocess.run(['uci', 'set', f'passwall2.{key}={value}']).returncode:
                raise RuntimeError(f'Could not set {key}')
        if remove_old_node:
            subprocess.run(['uci', 'delete', 'passwall2.ai_studio_fi'], check=True)
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
