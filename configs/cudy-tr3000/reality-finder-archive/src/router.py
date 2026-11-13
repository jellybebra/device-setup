"""Headless OpenWrt service. Control stays on a private Unix socket, never TCP."""
from __future__ import annotations

import argparse
import contextlib
import dataclasses
import json
import os
import pathlib
import re
import signal
import socket
import socketserver
import sqlite3
import sys
import threading
import time

from controller import Controller
from runtime import Core
from storage import Settings, Store, identity

LIMIT = 256 * 1024
DEFAULT_DATA = '/tmp/reality-finder'


class RouterCore(Core):
    def __init__(self, *args, mark=255, **kwargs):
        self.mark = mark
        super().__init__(*args, **kwargs)

    def configuration(self):
        config = super().configuration()
        config['outbounds'][1]['streamSettings']['sockopt']['mark'] = self.mark
        return config

    def outbound(self, node):
        config = super().outbound(node)
        config['streamSettings'].setdefault('sockopt', {})['mark'] = self.mark
        return config


def backup(store, target):
    """Consistent, atomic SQLite checkpoint. Never copy a live WAL file."""
    target = pathlib.Path(target)
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = target.with_suffix('.new')
    with store.lock, contextlib.closing(sqlite3.connect(temporary)) as destination:
        store.db.backup(destination)
    temporary.chmod(0o600)
    temporary.replace(target)


def restore(source, directory):
    target = directory / 'reality.sqlite3'
    if source and pathlib.Path(source).exists() and not target.exists():
        with contextlib.closing(sqlite3.connect(pathlib.Path(source).resolve().as_uri() + '?mode=ro', uri=True)) as old:
            with contextlib.closing(sqlite3.connect(target)) as new:
                old.backup(new)


class DataLock:
    def __init__(self, directory):
        import fcntl
        self.stream = (directory / 'service.lock').open('a')
        try:
            fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.stream.close()
            raise RuntimeError('Сервис с этой папкой данных уже запущен') from None

    def close(self):
        self.stream.close()


class RouterService:
    def __init__(self, store, core, checkpoint=None):
        self.store = store
        self.core = core
        self.checkpoint = checkpoint
        self.lock = threading.Lock()
        self.snapshot = {'reason': 'Запуск', 'nodes': []}
        self.updated = 0
        self.error = None
        self.controller = Controller(store, self.emit, core=core)
        self.controller.network_enabled = True

    def emit(self, kind, value):
        with self.lock:
            if kind == 'snapshot':
                self.snapshot = value
                self.updated = time.time()
                self.error = None
            elif kind == 'fatal':
                self.error = str(value)[:250]

    def handle(self, request):
        command = request.get('command')
        if command == 'status':
            with self.lock:
                value = json.loads(json.dumps(self.snapshot))
                value.update(updated_at=self.updated, error=self.error)
            value.update(relay_port=self.core.profile['port'], wan_interface=self.core.interface,
                         socket_mark=self.core.mark)
            subscription = self.store.get('subscription', {})
            value['subscription'] = {'enabled': subscription.get('enabled', False),
                                     **self.store.get('subscription_status', {})}
            # Status contains no credentials or full VLESS links.
            for node in [*value.get('nodes', []), value.get('active')]:
                if node:
                    node['id'] = identity(node.pop('uri'))
                    node.pop('source', None)
            value.pop('sources', None)
            return value
        if command == 'profile':
            return {'uri': self.core.uri, 'listen': '127.0.0.1'}
        if command == 'settings':
            return dataclasses.asdict(self.store.settings())
        if command == 'configure':
            settings = Settings(**request['settings']).validate()
            if settings.workers > 2 or settings.candidates > 300 or settings.reserves > 5:
                raise ValueError('Для роутера: workers ≤ 2, candidates ≤ 300, reserves ≤ 5')
            self.controller.configure(settings)
        elif command == 'import':
            from finder import parse_nodes
            text = request['text']
            nodes = parse_nodes(text, 'manual')
            if not nodes or len(nodes) > 300:
                raise ValueError('Нужно от 1 до 300 VLESS + Reality конфигураций')
            self.controller.paste(text)
        elif command == 'search':
            self.controller.search()
        elif command in ('recheck', 'prefer', 'exclude', 'include', 'switch'):
            key = request['id']
            if not re.fullmatch('[a-f0-9]{24}', key):
                raise ValueError('Некорректный ID узла')
            self.controller.action(command, key)
        elif command == 'save':
            if not self.checkpoint:
                raise ValueError('Постоянное хранилище не настроено')
            backup(self.store, self.checkpoint)
            return {'saved': True}
        else:
            raise ValueError('Неизвестная команда')
        return {'queued': True}


class ControlHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(5)
        try:
            line = self.rfile.readline(LIMIT + 1)
            if len(line) > LIMIT or not line.endswith(b'\n'):
                raise ValueError('Слишком большой или неполный запрос')
            result = {'ok': True, 'result': self.server.service.handle(json.loads(line))}
        except (OSError, ValueError, KeyError, TypeError) as error:
            result = {'ok': False, 'error': str(error)[:250]}
        with contextlib.suppress(OSError):
            self.wfile.write(json.dumps(result, ensure_ascii=False).encode() + b'\n')


def request(directory, value):
    payload = json.dumps(value).encode() + b'\n'
    if len(payload) > LIMIT:
        raise ValueError('Запрос превышает 256 КиБ')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(15)
        connection.connect(str(directory / 'control.sock'))
        connection.sendall(payload)
        with connection.makefile('rb') as stream:
            result = json.loads(stream.readline(16 * 1024 * 1024))
    if not result['ok']:
        raise RuntimeError(result['error'])
    return result['result']


def serve(args):
    directory = args.data_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    lock = DataLock(directory)
    store = server = service = None
    stopped = threading.Event()
    control = directory / 'control.sock'
    try:
        restore(args.checkpoint, directory)
        store = Store(directory)
        if not store.get('settings'):
            settings = Settings.mode('Экономный')
            settings.reserves = 2
            settings.candidates = 100
            settings.speed_budget_mib = 0
            settings.timeout = 8
            settings.autostart = False
            store.put('settings', dataclasses.asdict(settings))
        settings = store.settings()
        settings.workers = min(settings.workers, 2)
        settings.candidates = min(settings.candidates, 300)
        settings.reserves = min(settings.reserves, 5)
        store.put('settings', dataclasses.asdict(settings))
        from router_subscription import configure as configure_subscription
        unprotect = configure_subscription(store, args.subscription_file)
        core = RouterCore(store, store.settings().interface, xray=args.xray,
                          expected_sha256=args.sha256, quiet=True, mark=args.mark)
        if args.checkpoint and not args.checkpoint.exists():
            backup(store, args.checkpoint)
        service = RouterService(store, core, args.checkpoint)
        service.controller.publisher.unprotect = unprotect
        core.emit = service.emit
        control.unlink(missing_ok=True)
        server = socketserver.UnixStreamServer(str(control), ControlHandler)
        server.service = service
        server.timeout = 1
        control.chmod(0o600)
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda *_: stopped.set())
        # Fail early for incompatible Xray or occupied permanent port.
        core.start()
        service.controller.generation = core.generation
        service.controller.start()
        next_save = time.monotonic() + 21600
        while not stopped.is_set():
            server.handle_request()
            if args.checkpoint and time.monotonic() >= next_save:
                backup(store, args.checkpoint)
                next_save = time.monotonic() + 21600
    finally:
        if service:
            service.controller.close()
        if server:
            server.server_close()
        control.unlink(missing_ok=True)
        try:
            if store:
                if args.checkpoint:
                    backup(store, args.checkpoint)
                store.close()
        finally:
            lock.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=pathlib.Path, default=pathlib.Path(DEFAULT_DATA))
    commands = parser.add_subparsers(dest='command', required=True)
    run = commands.add_parser('serve')
    run.add_argument('--xray', type=pathlib.Path, required=True)
    run.add_argument('--sha256', required=True, help='SHA256 проверенного бинарника Xray')
    run.add_argument('--checkpoint', type=pathlib.Path)
    run.add_argument('--subscription-file', type=pathlib.Path)
    run.add_argument('--mark', type=lambda v: int(v, 0), default=255)
    for name in ('status', 'profile', 'settings', 'search', 'save'):
        commands.add_parser(name)
    for name in ('import', 'configure'):
        commands.add_parser(name).add_argument('file', type=pathlib.Path)
    for name in ('recheck', 'prefer', 'exclude', 'include', 'switch'):
        commands.add_parser(name).add_argument('id')
    args = parser.parse_args(argv)
    os.umask(0o077)
    if args.command == 'serve':
        if not re.fullmatch('[a-fA-F0-9]{64}', args.sha256):
            parser.error('--sha256 должен содержать 64 шестнадцатеричных символа')
        args.sha256 = args.sha256.lower()
        if not 0 <= args.mark <= 0xffffffff:
            parser.error('--mark должен быть unsigned 32-bit')
        serve(args)
        return
    value = {'command': args.command}
    if args.command in ('import', 'configure'):
        with args.file.open('rb') as stream:
            content = stream.read(LIMIT + 1)
        if len(content) > LIMIT:
            parser.error('Файл превышает 256 КиБ')
        if args.command == 'import':
            value['text'] = content.decode('utf-8-sig')
        else:
            value['settings'] = json.loads(content)
    if hasattr(args, 'id'):
        value['id'] = args.id
    print(json.dumps(request(args.data_dir, value), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
