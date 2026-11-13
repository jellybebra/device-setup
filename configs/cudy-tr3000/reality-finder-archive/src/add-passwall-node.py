"""Add/update a local Finder node without selecting it or restarting PassWall2."""
import os
import pathlib
import shutil
import subprocess
import sys
import time
import uuid
from urllib.parse import urlsplit

root = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(root.parent if root.name == 'openwrt' else root))
from router import request


def uci(*args, check=True):
    return subprocess.run(['uci', *args], capture_output=True, text=True, check=check).stdout.strip()


def main():
    os.umask(0o077)
    if os.geteuid() != 0:
        raise RuntimeError('Run as root on OpenWrt')
    if uci('changes', 'passwall2'):
        raise RuntimeError('PassWall2 has uncommitted changes; apply or revert them first')
    name = 'passwall2.reality_finder'
    existing = uci('-q', 'get', name, check=False)
    if existing and uci('-q', 'get', name + '.reality_finder_managed', check=False) != '1':
        raise RuntimeError('Existing reality_finder node is not managed by this script')
    profile = urlsplit(request(pathlib.Path('/tmp/reality-finder'), {'command': 'profile'})['uri'])
    if profile.hostname != '127.0.0.1' or not profile.port:
        raise RuntimeError('Expected a loopback Finder profile')
    identifier = str(uuid.UUID(profile.username))
    backup_dir = pathlib.Path('/etc/reality-finder/backups')
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = backup_dir / ('passwall2-' + str(time.time_ns()) + '.config')
    shutil.copyfile('/etc/config/passwall2', backup)
    backup.chmod(0o600)
    fields = {'remarks': 'Reality Finder (local auto)', 'type': 'Xray', 'protocol': 'vless',
              'address': '127.0.0.1', 'port': str(profile.port), 'uuid': identifier,
              'encryption': 'none', 'transport': 'raw', 'tcp_guise': 'none',
              'tls': '0', 'reality': '0', 'utls': '0', 'mux': '0', 'flow': '',
              'reality_finder_managed': '1'}
    try:
        uci('set', name + '=nodes')
        for key, value in fields.items():
            uci('set', name + '.' + key + '=' + value)
        uci('commit', 'passwall2')
    except BaseException:
        uci('revert', 'passwall2', check=False)
        raise
    print('Node ready: Reality Finder (local auto), 127.0.0.1:' + str(profile.port))
    print('Existing routing selections preserved; PassWall2 was not restarted.')
    print('Backup: ' + str(backup))


if __name__ == '__main__':
    main()
