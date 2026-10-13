import argparse
import concurrent.futures
import ctypes
import datetime
import json
import os
from pathlib import Path
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time
import urllib.request

parser = argparse.ArgumentParser(description='Paired STUN probes via Windows routing and a physical adapter; no route changes.')
parser.add_argument('--seconds', type=int, default=120)
parser.add_argument('--output-directory', type=Path, required=True)
parser.add_argument('--physical-interface', type=int, required=True)
parser.add_argument('--source-ip', required=True)
parser.add_argument('--ping', action='append', default=[])
parser.add_argument('--controller', default='http://127.0.0.1:10814')
parser.add_argument('--without-controller', action='store_true', help='Use when TUN is off; continue CPU and UDP measurements')
parser.add_argument('--game-pid', type=int, help='Record only whether this process owns the foreground window; no window titles')
parser.add_argument('--above-normal', action='store_true', help='Reduce scheduling delay of this diagnostic process')
args = parser.parse_args()
assert 1 <= args.seconds <= 300
DURATION = args.seconds
ROOT = args.output_directory.resolve()
ROOT.mkdir(parents=True, exist_ok=True)
STAMP = datetime.datetime.now().strftime('%H%M%S')
OUTPUT = ROOT / ('match-' + STAMP + '.jsonl')
LOCK = threading.Lock()
END = time.monotonic() + DURATION
records = []

def save(kind, **data):
    r = dict(at=datetime.datetime.now().astimezone().isoformat(), kind=kind, **data)
    with LOCK:
        records.append(r)
        with OUTPUT.open('a', encoding='utf-8') as f:
            f.write(json.dumps(r) + '\n')

def stun(ip, physical, size):
    mode = 'ethernet' if physical else 'automatic'
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        if physical:
            s.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', args.physical_interface))
            s.bind((args.source_ip, 0))
        s.connect((ip, 3478))
        save('probe_socket', mode=mode, size=size, local=s.getsockname(), remote=[ip, 3478])
        while time.monotonic() < END:
            tid = os.urandom(12)
            attr = b'' if size == 20 else struct.pack('!HH', 0x8022, size-24) + b'D' * (size-24)
            msg = struct.pack('!HHI', 1, len(attr), 0x2112a442) + tid + attr
            start = time.monotonic()
            deadline = start + 1.3
            s.send(msg)
            ms = None
            response_type = None
            while time.monotonic() < deadline:
                s.settimeout(deadline-time.monotonic())
                try:
                    reply = s.recv(4096)
                    if len(reply) >= 20 and reply[8:20] == tid:
                        ms = round((time.monotonic()-start)*1000, 2)
                        response_type = struct.unpack('!H', reply[:2])[0]
                        break
                except (socket.timeout, ConnectionResetError):
                    break
            save('stun', mode=mode, size=size, ip=ip, ms=ms, response_type=response_type)
            time.sleep(max(0, 1.5-(time.monotonic()-start)))

def ping(ip):
    p = subprocess.Popen(['ping.exe', '-n', str(DURATION), '-w', '800', '-S', args.source_ip, ip], stdout=subprocess.PIPE, text=True, encoding='utf-8', errors='replace', creationflags=0x08000000)
    for line in p.stdout:
        save('ping', ip=ip, line=line.strip())
    p.wait()

kernel = ctypes.WinDLL('kernel32', use_last_error=True)
kernel.GetSystemTimes.argtypes = [ctypes.POINTER(ctypes.c_ulonglong)] * 3
kernel.GetCurrentProcess.restype = ctypes.c_void_p
kernel.GetPriorityClass.argtypes = [ctypes.c_void_p]
kernel.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
if args.above_normal and not kernel.SetPriorityClass(kernel.GetCurrentProcess(), 0x8000):
    raise ctypes.WinError(ctypes.get_last_error())
user = ctypes.WinDLL('user32', use_last_error=True)
user.GetForegroundWindow.restype = ctypes.c_void_p
user.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]

def game_foreground():
    if args.game_pid is None:
        return None
    pid = ctypes.c_ulong()
    user.GetWindowThreadProcessId(user.GetForegroundWindow(), ctypes.byref(pid))
    return pid.value == args.game_pid
def cpu_times():
    vals = [ctypes.c_ulonglong() for _ in range(3)]
    if not kernel.GetSystemTimes(*(ctypes.byref(v) for v in vals)):
        raise ctypes.WinError(ctypes.get_last_error())
    return [v.value for v in vals]

def sample():
    prev = cpu_times()
    last = time.monotonic()
    previous_focus = game_foreground()
    focus_since = last
    while time.monotonic() < END:
        games, probes = [], []
        try:
            if args.without_controller:
                c = {'connections': []}
            else:
                request = urllib.request.Request(args.controller.rstrip('/') + '/connections')
                secret = os.environ.get('DEVICE_SETUP_CLASH_SECRET')
                if secret:
                    request.add_header('Authorization', 'Bearer ' + secret)
                with urllib.request.urlopen(request, timeout=2) as response:
                    c = json.load(response)
            games = [dict(id=x['id'], ip=x['metadata']['destinationIP'], port=x['metadata']['destinationPort'], upload=x['upload'], download=x['download'], chains=x['chains']) for x in c['connections'] if 'bf6.exe' in x['metadata'].get('processPath', '').lower() and x['metadata']['network'] == 'udp']
            probes = [dict(source_port=x['metadata']['sourcePort'], ip=x['metadata']['destinationIP'], chains=x['chains']) for x in c['connections'] if 'python' in x['metadata'].get('processPath', '').lower() and x['metadata']['destinationPort'] == '3478']
        except Exception as e:
            save('sample_error', error=str(e))
        now = cpu_times()
        total = now[1]+now[2]-prev[1]-prev[2]
        cpu = round(100*(1-(now[0]-prev[0])/total), 1) if total else None
        tick = time.monotonic()
        focus = game_foreground()
        if focus != previous_focus:
            focus_since, previous_focus = tick, focus
        save('sample', cpu=cpu, interval=round(tick-last, 3), games=games, probes=probes,
             game_foreground=focus, focus_unchanged_seconds=round(tick-focus_since, 3))
        prev, last = now, tick
        time.sleep(1)

print('OUTPUT', OUTPUT, flush=True)
ip = socket.getaddrinfo('stun.cloudflare.com', 3478, socket.AF_INET, socket.SOCK_DGRAM)[0][4][0]
save('start', duration=DURATION, stun_ip=ip, game_pid=args.game_pid,
     meter_priority_class=kernel.GetPriorityClass(kernel.GetCurrentProcess()))
with concurrent.futures.ThreadPoolExecutor(max_workers=5 + len(args.ping)) as pool:
    futures = [pool.submit(stun, ip, physical, size) for physical in (True, False) for size in (20, 1280)]
    futures += [pool.submit(ping, ip) for ip in args.ping]
    futures += [pool.submit(sample)]
    for f in futures:
        try:
            f.result()
        except Exception as e:
            save('worker_error', error=str(e))
summary = []
for mode in ('ethernet', 'automatic'):
    for size in (20, 1280):
        data = [r for r in records if r['kind'] == 'stun' and r['mode'] == mode and r['size'] == size]
        good = [r['ms'] for r in data if r['ms'] is not None]
        summary.append(dict(mode=mode, size=size, sent=len(data), lost=len(data)-len(good), median_ms=statistics.median(good) if good else None, max_ms=max(good) if good else None))
cpus = [r['cpu'] for r in records if r['kind'] == 'sample' and r['cpu'] is not None]
result = dict(probes=summary, cpu_median=statistics.median(cpus) if cpus else None, cpu_max=max(cpus) if cpus else None, output=str(OUTPUT))
OUTPUT.with_suffix('.summary.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result), flush=True)
