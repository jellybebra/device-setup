"""Temporary end-to-end Tunnel checks; serves only a random diagnostic string."""
import argparse
import hashlib
import json
import ipaddress
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--modes', nargs='+', default=['auto', 'http2', 'quic'])
    parser.add_argument('--doh-check', action='store_true', help='Resolve public test URL via direct DoH; retain hostname and TLS checks')
    parser.add_argument('--hold-seconds', type=int, default=0)
    parser.add_argument('--wait-dns', action='store_true', help='Wait for positive DoH answer before checking with normal system DNS')
    parser.add_argument('--label', default='')
    parser.add_argument('--bulk', action='store_true', help='Verify 2 MiB download, 512 KiB upload and a 20-second idle interval')
    args = parser.parse_args()
    label = 'tunnel-check-doh' if args.doh_check else 'tunnel-check'
    if args.hold_seconds:
        label += '-hold'
    if args.label:
        if not re.fullmatch(r'[a-z0-9-]+', args.label):
            parser.error('label must contain only lowercase letters, digits and hyphens')
        label += '-' + args.label
    root = args.state_dir / label
    root.mkdir(exist_ok=True)
    token = secrets.token_hex(16)
    payload = ('Cudy tunnel check ' + token).encode()
    bulk_payload = secrets.token_bytes(2 * 1024 * 1024)
    route = '/check/' + token

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in (route, route + '/large'):
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Cache-Control', 'no-store')
            body = bulk_payload if self.path.endswith('/large') else payload
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            length = int(self.headers.get('Content-Length', '0'))
            if self.path != route + '/upload' or not 0 < length <= len(bulk_payload):
                self.send_error(400)
                return
            self.connection.settimeout(15)
            body = hashlib.sha256(self.rfile.read(length)).hexdigest().encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    session = requests.Session()
    session.trust_env = False
    env = {k: v for k, v in os.environ.items()
           if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    results = []
    try:
        for mode in args.modes:
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                metrics = sock.getsockname()[1]
            log = root / f'{mode}.log'
            record = {'mode': mode, 'registered': False, 'public_body_ok': False}
            first_success = None
            dns_ready = False
            record['successful_checks'] = 0
            record['failed_checks'] = 0
            record['steady_failures'] = 0
            bulk_done = False
            print('Starting', mode, flush=True)
            with log.open('wb') as output:
                process = subprocess.Popen([
                    r'C:\Program Files (x86)\cloudflared\cloudflared.exe',
                    'tunnel', '--no-autoupdate', '--protocol', mode,
                    '--edge-ip-version', '4', '--metrics', f'127.0.0.1:{metrics}',
                    '--url', f'http://127.0.0.1:{server.server_port}',
                ], stdout=output, stderr=subprocess.STDOUT, env=env,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                try:
                    deadline = time.monotonic() + max(70, args.hold_seconds + 45)
                    while time.monotonic() < deadline and process.poll() is None:
                        content = log.read_text(encoding='utf-8', errors='replace')
                        url = re.search(r'https://[a-z0-9-]+\.trycloudflare\.com', content)
                        if 'Registered tunnel connection' in content:
                            record['registered'] = True
                            if url:
                                record['url'] = url.group()
                                try:
                                    if args.wait_dns and not dns_ready:
                                        answer = session.get('https://1.1.1.1/dns-query',
                                            params={'name': url.group().split('://', 1)[1], 'type': 'A'},
                                            headers={'Accept': 'application/dns-json'}, timeout=8).json()
                                        dns_ready = any(x['type'] == 1 for x in answer.get('Answer', []))
                                        if not dns_ready:
                                            time.sleep(2)
                                            continue
                                    if args.doh_check:
                                        host = url.group().split('://', 1)[1]
                                        answer = session.get('https://1.1.1.1/dns-query',
                                            params={'name': host, 'type': 'A'},
                                            headers={'Accept': 'application/dns-json'}, timeout=8).json()
                                        address = next(x['data'] for x in answer.get('Answer', [])
                                                       if x['type'] == 1 and ipaddress.ip_address(x['data']).is_global)
                                        result = subprocess.run(['curl.exe', '-4', '-sS', '--noproxy', '*',
                                            '--resolve', f'{host}:443:{address}', '--max-time', '10',
                                            '-w', '\n%{http_code}', url.group() + route],
                                            capture_output=True, timeout=12,
                                            creationflags=subprocess.CREATE_NO_WINDOW)
                                        body, _, status = result.stdout.rpartition(b'\n')
                                        record['status'] = status.decode(errors='replace')
                                        record['public_body_ok'] = result.returncode == 0 and status == b'200' and body == payload
                                        record['public_dns'] = 'direct DoH (system DNS bypassed for this request)'
                                    else:
                                        response = session.get(url.group() + route, timeout=8)
                                        record['status'] = response.status_code
                                        record['public_body_ok'] = response.status_code == 200 and response.content == payload
                                    if record['public_body_ok']:
                                        record['successful_checks'] += 1
                                        if first_success is None:
                                            first_success = time.monotonic()
                                        if args.bulk and not bulk_done:
                                            download = session.get(url.group() + route + '/large', timeout=30)
                                            record['download_ok'] = download.status_code == 200 and download.content == bulk_payload
                                            upload_body = bulk_payload[:512 * 1024]
                                            upload = session.post(url.group() + route + '/upload', data=upload_body, timeout=30)
                                            record['upload_ok'] = upload.status_code == 200 and upload.text == hashlib.sha256(upload_body).hexdigest()
                                            bulk_done = True
                                            print('Bulk check', mode, record['download_ok'], record['upload_ok'], flush=True)
                                            time.sleep(20)
                                        if time.monotonic() - first_success >= args.hold_seconds:
                                            break
                                    else:
                                        record['failed_checks'] += 1
                                        record['steady_failures'] += int(first_success is not None)
                                        if not args.doh_check:
                                            record['last_error_body'] = re.sub('<[^>]+>', ' ', response.text)[:300]
                                except (requests.RequestException, StopIteration, subprocess.TimeoutExpired) as error:
                                    record['request_error'] = str(error)[:250]
                                    record['failed_checks'] += 1
                                    record['steady_failures'] += int(first_success is not None)
                        time.sleep(2)
                    content = log.read_text(encoding='utf-8', errors='replace')
                    record['connections'] = [line.split('Registered tunnel connection', 1)[1].strip()
                                             for line in content.splitlines()
                                             if 'Registered tunnel connection' in line]
                    record['errors'] = [line for line in content.splitlines()
                                        if ' ERR ' in line or 'error=' in line][-5:]
                    record['observed_seconds'] = round(time.monotonic() - first_success, 1) if first_success else 0
                    record['stable'] = bool(first_success and record['observed_seconds'] >= args.hold_seconds
                                             and record['steady_failures'] == 0 and not record['errors']
                                             and (not args.bulk or (record.get('download_ok') and record.get('upload_ok'))))
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
            results.append(record)
            print(json.dumps(record, ensure_ascii=False), flush=True)
    finally:
        server.shutdown()
        server.server_close()
        session.close()
        (root / 'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
