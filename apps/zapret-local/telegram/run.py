#!/usr/bin/env python3
"""Run pinned TG WS Proxy with all asynchronous uplinks through Zapret SOCKS."""
import argparse
import asyncio
import json
import logging
import logging.handlers
import os
import re
import threading
from pathlib import Path
import ssl as tls
import struct
import sys


class ZapretConnector:
    def __init__(self, connect, port_provider):
        self.connect = connect
        self.port_provider = port_provider

    async def __call__(self, host, port, *, ssl=None, server_hostname=None,
                       limit=65536, **kwargs):
        if kwargs:
            raise ValueError(f'Unsupported connection options: {sorted(kwargs)}')
        if ssl is not None and (not isinstance(ssl, tls.SSLContext)
                                or not ssl.check_hostname
                                or ssl.verify_mode != tls.CERT_REQUIRED):
            raise ValueError('TLS must verify the certificate and destination hostname')
        writer = None
        try:
            async with asyncio.timeout(12):
                reader, writer = await self.connect('127.0.0.1', self.port_provider(), limit=limit)
                writer.write(b'\x05\x01\x00')
                await writer.drain()
                if await reader.readexactly(2) != b'\x05\x00':
                    raise ConnectionError('Zapret rejected SOCKS authentication')
                domain = host.encode('idna')
                if not 0 < len(domain) <= 255 or not 0 < int(port) <= 65535:
                    raise ValueError('Invalid SOCKS destination')
                writer.write(b'\x05\x01\x00\x03' + bytes([len(domain)]) + domain + struct.pack('!H', int(port)))
                await writer.drain()
                reply = await reader.readexactly(4)
                if reply[:3] != b'\x05\x00\x00':
                    raise ConnectionError(f'Zapret SOCKS connect failed: {reply.hex()}')
                if reply[3] == 1:
                    size = 4
                elif reply[3] == 4:
                    size = 16
                elif reply[3] == 3:
                    size = (await reader.readexactly(1))[0]
                else:
                    raise ConnectionError('Invalid SOCKS address type')
                await reader.readexactly(size + 2)
                if ssl is not None:
                    await writer.start_tls(ssl, server_hostname=server_hostname or host,
                                           ssl_handshake_timeout=8)
                return reader, writer
        except BaseException:
            if writer is not None:
                writer.close()
            raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--socks-port', type=int)
    parser.add_argument('--managed', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    upstream = Path(__file__).resolve().parent / 'upstream'
    if upstream.is_dir():
        sys.path.insert(0, str(upstream))
    from proxy.config import proxy_config, CFPROXY_DEFAULT_DOMAINS
    from proxy.tg_ws_proxy import run_proxy
    if args.self_test:
        import certifi
        import cryptography
        import httpx
        import h2.connection
        assert Path(certifi.where()).is_file()
        print('Embedded Telegram runtime OK')
        return
    if args.state_dir is None or args.socks_port is None:
        parser.error('--state-dir and --socks-port are required')
    if not 1024 <= args.socks_port <= 65535:
        parser.error('Invalid SOCKS port')
    root = args.state_dir
    settings = json.loads((root / 'settings.json').read_text())
    if not 1024 <= settings['port'] <= 65535 or not re.fullmatch(r'[0-9a-f]{32}', settings['secret']):
        raise ValueError('Invalid Telegram settings')
    if args.managed:
        # The app owns the write end. EOF also stops us after an app crash/SIGKILL.
        def watch_parent():
            while os.read(0, 1):
                pass
            os._exit(0)
        threading.Thread(target=watch_parent, daemon=True).start()
    start_server = asyncio.start_server

    async def ready_server(*positional, **kwargs):
        server = await start_server(*positional, **kwargs)
        ready = root / 'ready.json'
        temporary = root / 'ready.tmp'
        temporary.write_text(json.dumps({'pid': os.getpid(), 'port': settings['port']}))
        temporary.replace(ready)
        return server

    asyncio.start_server = ready_server
    proxy_config.host = '127.0.0.1'
    proxy_config.port = settings['port']
    proxy_config.secret = settings['secret']
    # A pinned list also disables the upstream background URL fetch. Thus DNS,
    # WS, TCP fallback and H2 media all stay within the Zapret socket path.
    proxy_config.cfproxy_user_domains = CFPROXY_DEFAULT_DOMAINS.copy()
    proxy_config.dc_redirects = {2: '149.154.167.220', 4: '149.154.167.220'}
    proxy_config.fallback_cfproxy = True

    asyncio.open_connection = ZapretConnector(asyncio.open_connection, lambda: args.socks_port)
    handler = logging.handlers.RotatingFileHandler(root / 'proxy.log', maxBytes=2_000_000, backupCount=2)

    class RedactSecret(logging.Filter):
        def filter(self, record):
            record.msg = record.getMessage().replace(settings['secret'], '[redacted]')
            record.args = ()
            return True

    handler.addFilter(RedactSecret())
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(name)s %(message)s'))
    logging.basicConfig(level=logging.INFO, handlers=[handler])
    run_proxy()


if __name__ == '__main__':
    os.umask(0o077)
    main()
