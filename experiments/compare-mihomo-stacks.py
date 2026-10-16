"""Compare Windows Mihomo stacks using one temporary STUN host route.

Experimental diagnostic, not a validated remedy: the October 15 attempts
stalled during adapter/route enumeration before collecting stack measurements.
Run elevated only during a maintenance window. The script does not intentionally
change the working core, default routes, DNS or firewall, and verifies cleanup.
Only 162.159.207.0/32 is routed to the temporary adapter. Each phase removes
that route and stops its own core, including after errors. No VPN keys needed.
"""
import argparse
import ctypes
import datetime
import ipaddress
import json
import math
import os
import re
from pathlib import Path
import socket
import statistics
import struct
import subprocess
import threading
import time

TARGET = '162.159.207.0'
DEVICE = 'mihomo_probe'
NETWORK = ipaddress.ip_network('172.29.231.0/30')
HIDDEN = subprocess.CREATE_NO_WINDOW


def native(*command):
    r = subprocess.run(command, capture_output=True, timeout=15,
                       creationflags=HIDDEN)
    if r.returncode:
        raise RuntimeError(repr(command)+': '+r.stderr.decode(errors='replace'))
    return r.stdout.decode(errors='replace')


def adapter_index():
    # CIM can stall while a TUN is being created. AliasToLuid can retain a
    # removed adapter's stale index, so inspect the live native IPv4 table.
    for line in native('netsh.exe', 'interface', 'ipv4', 'show', 'interfaces').splitlines():
        cells = line.split(None, 4)
        if len(cells) == 5 and cells[0].isdigit() and cells[4] == DEVICE:
            return int(cells[0])
    return None


def routes():
    rows = []
    for line in native('route.exe', 'PRINT', '-4').splitlines():
        match = re.match(r'^\s*(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\S+)\s+(\S+)\s+(\d+)\s*$', line)
        if match:
            destination, mask, gateway, interface, metric = match.groups()
            rows.append({'prefix': str(ipaddress.IPv4Network((destination, mask), strict=False)),
                         'gateway': gateway, 'interface': interface, 'metric': int(metric)})
    if not any(r['prefix'] == '0.0.0.0/0' for r in rows):
        raise RuntimeError('Could not parse the native route table')
    return rows


def default_routes():
    return sorted((r['gateway'], r['interface'], r['metric']) for r in routes() if r['prefix']=='0.0.0.0/0')


def probe(sock):
    tid = os.urandom(12)
    packet = struct.pack('!HHI', 1, 0, 0x2112a442) + tid
    start = time.monotonic()
    try:
        sock.send(packet)
        while time.monotonic() - start < 1.2:
            sock.settimeout(max(.001, 1.2 - (time.monotonic() - start)))
            reply = sock.recv(4096)
            if len(reply) >= 20 and reply[8:20] == tid:
                return round((time.monotonic() - start) * 1000, 3)
    except OSError:
        pass
    return None


def stats(samples):
    good = sorted(x for x in samples if x is not None)
    return dict(n=len(samples), timeouts=len(samples)-len(good),
                median=statistics.median(good) if good else None,
                p95=good[math.ceil(len(good)*.95)-1] if good else None,
                maximum=max(good) if good else None)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--core', type=Path, required=True)
    ap.add_argument('--physical-interface', type=int, required=True)
    ap.add_argument('--source-ip', required=True)
    ap.add_argument('--game-pid', type=int, required=True)
    ap.add_argument('--seconds', type=int, default=30)
    ap.add_argument('--stacks', nargs='+', choices=['mips', 'gvisor', 'system'],
                    default=['mips', 'gvisor', 'system'])
    args = ap.parse_args()
    if not ctypes.windll.shell32.IsUserAnAdmin():
        raise SystemExit('Run elevated for the temporary adapter and host route')
    if not 10 <= args.seconds <= 60:
        raise SystemExit('Expected 10..60 seconds per stack')
    ipaddress.IPv4Address(args.source_ip)
    args.output.mkdir(parents=True, exist_ok=False)
    with socket.socket() as port_check:
        port_check.bind(('127.0.0.1', 19721))
    existing = [r['prefix'] for r in routes()]
    if any(ipaddress.ip_network(x).prefixlen and ipaddress.ip_network(x).overlaps(NETWORK) for x in existing):
        raise SystemExit('Diagnostic subnet overlaps an existing route')
    if TARGET+'/32' in existing:
        raise SystemExit('Diagnostic target already has a host route')
    if adapter_index() is not None:
        raise SystemExit('Diagnostic adapter already exists')
    before = default_routes()
    kernel = ctypes.WinDLL('kernel32')
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    kernel.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    kernel.SetPriorityClass(kernel.GetCurrentProcess(), 0x8000)
    kernel.GetSystemTimes.argtypes = [ctypes.POINTER(ctypes.c_ulonglong)] * 3
    user = ctypes.WinDLL('user32')
    user.GetForegroundWindow.restype = ctypes.c_void_p
    user.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]

    def cpu_times():
        values = [ctypes.c_ulonglong() for _ in range(3)]
        kernel.GetSystemTimes(*(ctypes.byref(x) for x in values))
        return [x.value for x in values]

    results = []
    try:
        for stack in args.stacks:
            proc, timer, index = None, None, None
            route_added = False
            config = {'mixed-port': 19721, 'bind-address': '127.0.0.1',
                      'allow-lan': False, 'ipv6': False, 'mode': 'rule',
                      'log-level': 'warning', 'interface-name': 'Ethernet',
                      # Mihomo derives the TUN IPv4 prefix from fake-ip-range,
                      # even with its DNS listener disabled. RawTun ignores
                      # inet4-address in 1.19.32.
                      'dns': {'enable': False, 'fake-ip-range': '172.29.231.1/30'},
                      'rules': ['MATCH,DIRECT'],
                      'tun': {'enable': True, 'device': DEVICE, 'stack': stack,
                              'mtu': 1500,
                              'auto-route': False, 'auto-detect-interface': False,
                              'strict-route': False, 'dns-hijack': []}}
            path = args.output/(stack+'.json')
            path.write_text(json.dumps(config, indent=2))
            try:
                with (args.output/(stack+'.log')).open('w') as log:
                    proc = subprocess.Popen([str(args.core), '-d', str(args.output), '-f', str(path)],
                                            stdout=log, stderr=log, creationflags=HIDDEN)
                    timer = threading.Timer(150, lambda p=proc: p.terminate() if p.poll() is None else None)
                    timer.start()
                    time.sleep(3)
                    if proc.poll() is not None:
                        raise RuntimeError('Test core exited; see '+stack+'.log')
                    index = adapter_index()
                    if index is None:
                        raise RuntimeError('Test adapter was not created; see '+stack+'.log')
                    if before != default_routes():
                        raise RuntimeError('Default routes changed unexpectedly')
                    native('route.exe', 'ADD', TARGET, 'MASK', '255.255.255.255', '172.29.231.2', 'METRIC', '1', 'IF', str(index))
                    route_added = True
                    rows = []
                    prior = cpu_times()
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as direct, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as tun:
                        direct.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', args.physical_interface))
                        direct.bind((args.source_ip, 0))
                        direct.connect((TARGET, 3478))
                        tun.bind(('172.29.231.1', 0))
                        tun.connect((TARGET, 3478))
                        deadline = time.monotonic()+args.seconds
                        print('MEASURING '+stack, flush=True)
                        while time.monotonic() < deadline:
                            row = {'at': datetime.datetime.now().astimezone().isoformat()}
                            order = [('physical', direct), ('tun', tun)]
                            for label, sock in order if len(rows)%2 else reversed(order):
                                row[label] = probe(sock)
                            now = cpu_times()
                            total = now[1]+now[2]-prior[1]-prior[2]
                            row['cpu'] = 100*(1-(now[0]-prior[0])/total) if total else None
                            prior = now
                            pid = ctypes.c_ulong()
                            user.GetWindowThreadProcessId(user.GetForegroundWindow(), ctypes.byref(pid))
                            row['game_foreground'] = pid.value == args.game_pid
                            rows.append(row)
                            time.sleep(.2)
                    result = {'stack': stack, 'samples': rows,
                              'summary': {p: stats([r[p] for r in rows]) for p in ['physical', 'tun']},
                              'cpu_median': statistics.median(r['cpu'] for r in rows if r['cpu'] is not None),
                              'foreground_samples': sum(r['game_foreground'] for r in rows)}
                    results.append(result)
                    (args.output/'results.json').write_text(json.dumps(results, indent=2))
                    print(json.dumps({k:v for k,v in result.items() if k!='samples'}), flush=True)
            finally:
                try:
                    if route_added:
                        native('route.exe', 'DELETE', TARGET, 'MASK', '255.255.255.255', '172.29.231.2', 'IF', str(index))
                finally:
                    if timer: timer.cancel()
                    if proc is not None and proc.poll() is None:
                        proc.terminate()
                        try: proc.wait(timeout=10)
                        except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=10)
    except BaseException as exc:
        (args.output/'error.json').write_text(json.dumps({'error': str(exc)}))
        raise
    finally:
        cleanup = {}
        for name, query in {
            'default_routes_unchanged': lambda: before == default_routes(),
            'residual_host_route': lambda: [r for r in routes() if r['prefix']==TARGET+'/32'],
            'residual_adapter': adapter_index,
        }.items():
            try:
                cleanup[name] = query()
            except Exception as exc:
                cleanup[name+'_verification_error'] = str(exc)
        (args.output/'cleanup.json').write_text(json.dumps(cleanup, indent=2))


if __name__ == '__main__':
    main()
