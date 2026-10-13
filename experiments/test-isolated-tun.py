"""Windows UDP stack comparison using only a private connected /30, never a default route.

Requires elevation for Wintun. Keep v2rayN TUN off during this diagnostic.
The private test destination is rewritten to Cloudflare STUN by a separate core.
No system proxy, DNS, registry, game settings or v2rayN configuration are changed.
"""
import argparse
import ctypes
import datetime
import json
import math
import os
from pathlib import Path
import socket
import statistics
import struct
import subprocess
import time
import traceback


def powershell(command):
    r = subprocess.run(['powershell.exe', '-NoProfile', '-Command', command],
                       capture_output=True, text=True, timeout=30,
                       creationflags=subprocess.CREATE_NO_WINDOW, check=True)
    return r.stdout.strip()


def stats(rows):
    v = sorted(x for x in rows if x is not None)
    return dict(sent=len(rows), timeouts=len(rows)-len(v),
                median_ms=round(statistics.median(v), 3) if v else None,
                p95_ms=round(v[math.ceil(len(v)*.95)-1], 3) if v else None,
                max_ms=round(max(v), 3) if v else None)


def probe(sock):
    tid = os.urandom(12)
    data = struct.pack('!HHI', 1, 0, 0x2112a442) + tid
    start = time.monotonic()
    try:
        sock.send(data)
        while time.monotonic() - start < 1:
            sock.settimeout(max(.001, 1-(time.monotonic()-start)))
            reply = sock.recv(4096)
            if len(reply) >= 20 and reply[8:20] == tid:
                return (time.monotonic()-start)*1000
    except (TimeoutError, ConnectionResetError):
        pass
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', type=Path, required=True)
    ap.add_argument('--output-directory', type=Path, required=True)
    ap.add_argument('--source-ip', required=True)
    ap.add_argument('--physical-interface', type=int, required=True)
    ap.add_argument('--seconds', type=int, default=25)
    ap.add_argument('--stacks', nargs='+', choices=('mixed', 'system', 'gvisor'),
                    default=['mixed', 'system', 'gvisor'])
    args = ap.parse_args()
    if not ctypes.windll.shell32.IsUserAnAdmin():
        raise SystemExit('Administrator rights required for the isolated Wintun adapter')
    if not 5 <= args.seconds <= 60:
        raise SystemExit('Seconds must be between 5 and 60 per stack')
    root = args.output_directory.resolve()
    root.mkdir(parents=True, exist_ok=False)
    # Refuse an existing adapter or any route more specific than the normal default
    # covering the chosen private subnet; no existing network is repurposed.
    import ipaddress
    raw = powershell("Get-NetRoute -AddressFamily IPv4 | Select-Object -ExpandProperty DestinationPrefix | ConvertTo-Json")
    prefixes = json.loads(raw)
    for prefix in prefixes if isinstance(prefixes, list) else [prefixes]:
        net = ipaddress.ip_network(prefix)
        if net.prefixlen and net.overlaps(ipaddress.ip_network('172.29.231.0/30')):
            raise SystemExit('Existing route overlaps the private diagnostic network: '+prefix)
    if powershell("Get-NetAdapter | Where-Object Name -eq 'codex_udp_probe' | Select-Object -ExpandProperty Name"):
        raise SystemExit('Diagnostic adapter already exists')
    before = powershell("Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceIndex,NextHop,RouteMetric | ConvertTo-Json -Compress")
    results = []
    try:
        for stack in args.stacks:
            config = dict(log=dict(level='warn'),
                          inbounds=[dict(type='tun', tag='test', interface_name='codex_udp_probe',
                                         address=['172.29.231.1/30'], mtu=9000,
                                         auto_route=False, strict_route=False, stack=stack)],
                          outbounds=[dict(type='direct', tag='physical', inet4_bind_address=args.source_ip)],
                          route=dict(rules=[dict(inbound=['test'], network='udp',
                                                ip_cidr=['172.29.231.2/32'], port=[3478],
                                                action='route', outbound='physical',
                                                override_address='162.159.207.0', override_port=3478),
                                            dict(action='reject')]))
            path = root / (stack+'.json')
            path.write_text(json.dumps(config, indent=2))
            subprocess.run([str(args.core), 'check', '-c', str(path)], check=True,
                           capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
            proc = None
            try:
                with (root/(stack+'.log')).open('w') as log:
                    proc = subprocess.Popen([str(args.core), 'run', '-c', str(path)],
                                            stdout=log, stderr=log,
                                            creationflags=subprocess.CREATE_NO_WINDOW)
                    time.sleep(3)
                    if proc.poll() is not None:
                        raise RuntimeError(stack+' core exited; see its log')
                    route = powershell("Get-NetRoute -AddressFamily IPv4 | Where-Object DestinationPrefix -eq '172.29.231.0/30' | Select-Object InterfaceIndex,DestinationPrefix,NextHop | ConvertTo-Json -Compress")
                    if not route:
                        raise RuntimeError('Private connected route was not created')
                    rows = dict(physical=[], tun=[])
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as direct, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as tun:
                        direct.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', args.physical_interface))
                        direct.bind((args.source_ip, 0))
                        direct.connect(('162.159.207.0', 3478))
                        tun.bind(('172.29.231.1', 0))
                        tun.connect(('172.29.231.2', 3478))
                        deadline = time.monotonic() + args.seconds
                        while time.monotonic() < deadline:
                            for label, sock in (('physical', direct), ('tun', tun)):
                                rows[label].append(probe(sock))
                            time.sleep(.2)
                    results.append(dict(stack=stack, at=datetime.datetime.now().astimezone().isoformat(),
                                        route=json.loads(route), summary={k:stats(v) for k,v in rows.items()}, samples=rows))
                    (root/'results.json').write_text(json.dumps(results, indent=2))
            finally:
                if proc is not None and proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=10)
                time.sleep(1)
    except BaseException as exc:
        (root/'error.json').write_text(json.dumps(dict(error=str(exc), traceback=traceback.format_exc()), indent=2))
        raise
    finally:
        try:
            after = powershell("Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceIndex,NextHop,RouteMetric | ConvertTo-Json -Compress")
            residual = powershell("Get-NetRoute -AddressFamily IPv4 | Where-Object DestinationPrefix -eq '172.29.231.0/30' | Select-Object InterfaceIndex,DestinationPrefix | ConvertTo-Json -Compress")
            cleanup = dict(default_routes_unchanged=before==after, private_route_remaining=residual)
        except Exception as exc:
            cleanup = dict(verification_error=str(exc))
        (root/'cleanup.json').write_text(json.dumps(cleanup, indent=2))


if __name__ == '__main__':
    main()
