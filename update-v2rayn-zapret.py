#!/usr/bin/env python3
"""Add social routes to an existing macOS v2rayN Zapret profile, without Reload."""
import argparse
from contextlib import closing
from datetime import datetime
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import uuid

RULES = Path(__file__).resolve().parent / 'configs/v2rayn/macos/zapret/social-routes.json'


def connect(path, mode='rw'):
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=' + mode, uri=True, timeout=15)
    db.row_factory = sqlite3.Row
    return db


def patch_rules(existing, additions, title_key):
    titles = {r[title_key] for r in additions}
    return additions + [r for r in existing if r.get(title_key) not in titles]


def update(app, backup_root, check=False):
    db_path = app / 'guiConfigs/guiNDB.db'
    config_path = app / 'guiConfigs/guiNConfig.json'
    config_bytes = config_path.read_bytes()
    runtime = json.loads((app / 'binConfigs/config.json').read_text())
    with closing(connect(db_path)) as db:
        active = db.execute('SELECT * FROM RoutingItem WHERE IsActive=1').fetchall()
        if len(active) != 1:
            raise ValueError('Expected exactly one active routing profile')
        saved = dict(active[0])
        old = json.loads(saved['RuleSet'])
        discord = [r for r in old if 'geosite:discord' in r.get('Domain', []) and r.get('Enabled')]
        if len(discord) != 1:
            raise ValueError('Expected one existing Discord route through Zapret')
        tag = discord[0]['OutboundTag']
        profiles = db.execute('SELECT * FROM ProfileItem WHERE Remarks=?', (tag,)).fetchall()
        if len(profiles) != 1:
            raise ValueError('Zapret outbound must identify one existing SOCKS profile')
        profile = dict(profiles[0])
        if profile['ConfigType'] != 4 or profile['Address'] not in ('127.0.0.1', 'localhost'):
            raise ValueError('Zapret profile is not a local SOCKS proxy')
        runtime_tags = [r['outboundTag'] for r in runtime['routing']['rules']
                        if 'geosite:discord' in r.get('domain', [])]
        if len(runtime_tags) != 1:
            raise ValueError('Running configuration does not identify the Discord outbound')
        runtime_tag = runtime_tags[0]
        outbound = next(o for o in runtime['outbounds'] if o['tag'] == runtime_tag)
        settings = outbound.get('settings', {})
        server = settings.get('servers', [settings])[0]
        if (outbound['protocol'] != 'socks' or server.get('address') != profile['Address']
                or server.get('port') != profile['Port']):
            raise ValueError('Running Zapret outbound differs from the saved profile')
        with socket.create_connection((profile['Address'], profile['Port']), timeout=3) as sock:
            sock.sendall(b'\x05\x01\x00')
            if sock.recv(2) != b'\x05\x00':
                raise ValueError('Zapret SOCKS handshake failed')
        additions = []
        xray_rules = []
        for rule in json.loads(RULES.read_text()):
            saved_rule = {k[0].upper() + k[1:]: v for k, v in rule.items()}
            saved_rule['OutboundTag'] = tag if rule['outboundTag'] == 'zapret' else rule['outboundTag']
            previous = next((r for r in old if r.get('Remarks') == rule['remarks']), None)
            saved_rule['Id'] = previous['Id'] if previous else uuid.uuid4().hex
            additions.append(saved_rule)
            xray_rules.append({'type': 'field', **{k: v for k, v in rule.items()
                               if k not in ('remarks', 'enabled', 'outboundTag')},
                               'outboundTag': runtime_tag if rule['outboundTag'] == 'zapret' else rule['outboundTag']})
        new = patch_rules(old, additions, 'Remarks')
        # Test with the actual installed geosite assets and existing outbounds.
        candidate = json.loads(json.dumps(runtime))
        candidate['routing']['rules'] = xray_rules + candidate['routing']['rules']
        env = dict(os.environ, XRAY_LOCATION_ASSET=str(app / 'bin'))
        with tempfile.TemporaryDirectory(prefix='v2rayn-zapret-check-') as folder:
            path = Path(folder) / 'config.json'
            path.write_text(json.dumps(candidate))
            result = subprocess.run([str(app / 'bin/xray/xray'), 'run', '-test', '-config', str(path)],
                                    env=env, capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise ValueError('Xray validation failed: ' + result.stdout + result.stderr)
        # Full templates bypass RoutingItem. Require them disabled rather than
        # silently leaving an enabled template with different routing.
        templates = [dict(r) for r in db.execute('SELECT * FROM FullConfigTemplateItem')]
        if any(r['Enabled'] for r in templates):
            raise ValueError('Disable full configuration templates before using this routing updater')
        print(f"Validated: {saved['Remarks']}; {tag} at {profile['Address']}:{profile['Port']}")
        if check or new == old:
            print('Already current.' if new == old else 'Update available. No settings changed.')
            return
        db.execute('BEGIN IMMEDIATE')
        try:
            current = db.execute('SELECT * FROM RoutingItem WHERE IsActive=1').fetchall()
            if ([dict(r) for r in current] != [saved] or config_path.read_bytes() != config_bytes
                    or [dict(r) for r in db.execute('SELECT * FROM FullConfigTemplateItem')] != templates
                    or dict(db.execute('SELECT * FROM ProfileItem WHERE IndexId=?', (profile['IndexId'],)).fetchone()) != profile):
                raise ValueError('Settings changed during validation; retry')
            backup = backup_root / (datetime.now().strftime('zapret-social-%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8])
            backup.mkdir(parents=True, mode=0o700)
            with closing(connect(db_path, 'ro')) as source, closing(sqlite3.connect(backup / 'guiNDB.db')) as dest:
                source.backup(dest)
            (backup / 'guiNConfig.json').write_bytes(config_bytes)
            db.execute('UPDATE RoutingItem SET RuleSet=?, RuleNum=? WHERE Id=?',
                       (json.dumps(new, ensure_ascii=False), len(new), saved['Id']))
            row = db.execute('SELECT * FROM RoutingItem WHERE Id=?', (saved['Id'],)).fetchone()
            if json.loads(row['RuleSet']) != new or row['RuleNum'] != len(new):
                raise ValueError('Saved route verification failed')
            if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('Database integrity check failed')
            db.commit()
        except BaseException:
            db.rollback()
            raise
        print(f'Updated {len(old)} -> {len(new)} rules. Backup: {backup}')
        print('Press Reload in v2rayN. No services were restarted.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-dir', type=Path, default=Path.home() / 'Library/Application Support/v2rayN')
    parser.add_argument('--backup-root', type=Path, default=Path.home() / 'Library/Application Support/v2rayN-backups')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    update(args.app_dir.resolve(), args.backup_root.resolve(), args.check)


if __name__ == '__main__':
    main()
