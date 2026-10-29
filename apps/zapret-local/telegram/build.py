#!/usr/bin/env python3
"""Freeze the pinned Telegram transport, including Python and dependencies."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REVISION = '307a384ab7f522e34bb1a045884d0bd90f40bee5'
ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run(list(map(str, args)), check=True)

def output(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--target', required=True)
    args = parser.parse_args()
    arch = {'aarch64-apple-darwin': 'arm64', 'x86_64-apple-darwin': 'x86_64', 'universal-apple-darwin': 'universal2'}[args.target]
    build = ROOT / '.build/telegram' / args.target
    build.mkdir(parents=True, exist_ok=True)
    checkout = Path(os.environ.get('ZAPRET_TG_SOURCE', ROOT / '.build/tg-ws-source'))
    if not checkout.exists():
        bare = ROOT / '.build/tg-ws.git'
        if not bare.exists():
            run('git', 'clone', '--bare', 'https://github.com/Flowseal/tg-ws-proxy.git', bare)
        run('git', '--git-dir', bare, 'worktree', 'add', '-b', 'task/embedded-telegram', checkout, REVISION)
    if output('git', '-C', checkout, 'rev-parse', 'HEAD') != REVISION or output('git', '-C', checkout, 'status', '--porcelain', '--untracked-files=no'):
        raise SystemExit('TG WS Proxy checkout must be clean and at the pinned revision')
    venv = build / 'venv'
    if not venv.exists():
        run(sys.executable, '-m', 'venv', venv)
    python = venv / 'bin/python'
    run(python, '-m', 'pip', 'install', '-r', ROOT / 'telegram/build-requirements.txt')
    licenses = build / 'licenses'
    licenses.mkdir(exist_ok=True)
    run(python, ROOT / 'telegram/collect_licenses.py', licenses)
    shutil.copy2(checkout / 'LICENSE', licenses / 'Flowseal-tg-ws-proxy-LICENSE.txt')
    run(python, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--name', 'zapret-telegram',
        '--target-arch', arch, '--paths', checkout, '--collect-submodules', 'proxy', '--collect-all', 'certifi',
        '--add-data', f'{licenses}:licenses', '--distpath', build / 'dist', '--workpath', build / 'work',
        '--specpath', build, ROOT / 'telegram/run.py')
    destination = ROOT / 'binaries' / f'telegram-{args.target}'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(build / 'dist/zapret-telegram', destination, symlinks=True)
    (destination / 'build.json').write_text(json.dumps({'upstreamRevision': REVISION, 'target': args.target}) + '\n')
    run(destination / 'zapret-telegram', '--self-test')

if __name__ == '__main__':
    main()
