"""Compare native and existing userspace WireGuard to the same private UDP echo.

Server mode listens only on the task WG address, accepts only the two test peers,
does not amplify packets, and exits after a bounded interval. No public listener.
Client mode needs the native server-only route and existing SOCKS 19506.
"""
import argparse
import ctypes
import datetime
import importlib.util
import json
import math
import os
from pathlib import Path
import socket
import statistics
import time

TARGET = ('10.203.13.1', 19516)


def stats(rows):
    values = sorted(x for x in rows if x is not None)
    return dict(sent=len(rows), timeouts=len(rows)-len(values),
                median_ms=round(statistics.median(values), 3) if values else None,
                p95_ms=round(values[math.ceil(len(values)*.95)-1], 3) if values else None,
                p99_ms=round(values[math.ceil(len(values)*.99)-1], 3) if values else None,
                max_ms=round(max(values), 3) if values else None)


def cpu_times():
    idle, kernel, user = (ctypes.c_ulonglong() for _ in range(3))
    if not ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)):
        raise ctypes.WinError()
    return idle.value, kernel.value + user.value


def server(seconds):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(TARGET)
        sock.settimeout(1)
        deadline = time.monotonic() + seconds
        print('Private UDP echo ready, bounded lifetime', flush=True)
        while time.monotonic() < deadline:
            try:
                packet, sender = sock.recvfrom(1201)
                if sender[0] in ('10.203.13.2', '10.203.13.4') and len(packet) <= 1200 and packet.startswith(b'WGPROBE1'):
                    sock.sendto(packet, sender)
            except TimeoutError:
                pass


def query(sock, address, header):
    payload = b'WGPROBE1' + os.urandom(24) + bytes(992)
    started = time.perf_counter()
    sock.sendto(header + payload, address)
    deadline = time.monotonic() + 1
    try:
        while time.monotonic() < deadline:
            sock.settimeout(max(.001, deadline-time.monotonic()))
            packet, sender = sock.recvfrom(4096)
            if sender == address and packet == header + payload:
                return round((time.perf_counter()-started)*1000, 3)
    except (TimeoutError, ConnectionResetError):
        pass
    return None


def client(args):
    if args.priority == 'above-normal':
        ctypes.windll.kernel32.GetCurrentProcess.restype = ctypes.c_void_p
        ctypes.windll.kernel32.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        if not ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x8000):
            raise ctypes.WinError()
    # Reuse the existing SOCKS handshake without logging any configuration keys.
    spec = importlib.util.spec_from_file_location('compare_proxies', Path(__file__).with_name('compare-proxies.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    proxy = module.UDP(19506)
    header = b'\x00\x00\x00\x01' + socket.inet_aton(TARGET[0]) + TARGET[1].to_bytes(2, 'big')
    report = dict(started=datetime.datetime.now().astimezone().isoformat(),
                  payload_bytes=1024, meter_priority=args.priority,
                  samples={'native': [], 'userspace': []}, cpu_percent=[])
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as native:
            native.bind(('10.203.13.4', 0))
            methods = {'native': (native, TARGET, b''), 'userspace': (proxy.udp, proxy.relay, header)}
            warmup = {label: [query(*parameters) for _ in range(3)] for label, parameters in methods.items()}
            report['warmup'] = warmup
            if any(all(x is None for x in rows) for rows in warmup.values()):
                raise RuntimeError('One path failed all warmup probes; no comparison was run')
            previous = cpu_times()
            deadline = time.monotonic() + args.seconds
            index = 0
            while time.monotonic() < deadline:
                for label in (('native', 'userspace') if index % 2 == 0 else ('userspace', 'native')):
                    report['samples'][label].append(query(*methods[label]))
                current = cpu_times()
                total = current[1]-previous[1]
                if total:
                    report['cpu_percent'].append(round(100*(1-(current[0]-previous[0])/total), 2))
                previous = current
                index += 1
                time.sleep(.15)
    except Exception as exc:
        report['error'] = str(exc)
        raise
    finally:
        proxy.close()
        report['summary'] = {label: stats(rows) for label, rows in report['samples'].items()}
        report['cpu_median'] = statistics.median(report['cpu_percent']) if report['cpu_percent'] else None
        args.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
        print(json.dumps({k: report[k] for k in ('summary', 'cpu_median')}, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', action='store_true')
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--priority', choices=('normal', 'above-normal'), default='normal')
    args = parser.parse_args()
    if not 5 <= args.seconds <= (600 if args.server else 300):
        parser.error('seconds must be 5..300 for a client or 5..600 for the server')
    if args.server:
        server(args.seconds)
    elif args.output:
        client(args)
    else:
        parser.error('--output is required for the Windows client')
