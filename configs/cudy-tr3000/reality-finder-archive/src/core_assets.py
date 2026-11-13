"""Pinned upstream Xray artifacts; each platform verifies its official archive."""
import json
import pathlib
import platform
import sys

VERSION = '26.3.27'
ROOT = pathlib.Path(getattr(sys, '_MEIPASS', pathlib.Path(__file__).resolve().parent))
ARTIFACTS = {
    ('win32', 'x86_64'): ('Xray-windows-64.zip', 'd004c39288ce9ada487c6f398c7c545f7d749e44bdfdd59dbc9f865afba4e1ad'),
    ('darwin', 'x86_64'): ('Xray-macos-64.zip', 'f5b0471d3459eff1b82e48af0aeac186abcc3298210070afbbbd8437a4e8b203'),
    ('darwin', 'arm64'): ('Xray-macos-arm64-v8a.zip', '2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf'),
}
WINDOWS_SHA256 = '15c2d007954ac53ba69b80ec91242786b3c0b71d52649165b4ca1d5cc96ef8f1'


def artifact():
    machine = platform.machine().lower()
    machine = {'amd64': 'x86_64', 'aarch64': 'arm64'}.get(machine, machine)
    try: return ARTIFACTS[(sys.platform, machine)]
    except KeyError: raise RuntimeError(f'Сборка Xray не настроена для {sys.platform}/{machine}')


def binary(): return ROOT / 'bin' / ('xray.exe' if sys.platform == 'win32' else 'xray')


def executable_hash():
    manifest = ROOT / 'bin' / 'core-manifest.json'
    if manifest.exists():
        value = json.loads(manifest.read_text(encoding='utf-8'))
        name, archive_hash = artifact()
        if value.get('version') != VERSION or value.get('archive') != name or value.get('archive_sha256') != archive_hash:
            raise ValueError('Некорректный манифест Xray; повторите bootstrap_core.py')
        return value['executable_sha256']
    if sys.platform == 'win32': return WINDOWS_SHA256
    raise FileNotFoundError('Нет манифеста Xray; выполните python bootstrap_core.py')


def curl(): return 'curl.exe' if sys.platform == 'win32' else '/usr/bin/curl'
