import argparse
import ctypes as c
from ctypes import wintypes as w
import datetime
import json
import hashlib
from pathlib import Path
import socket
import struct
import threading
import time

p = argparse.ArgumentParser()
p.add_argument('--output-directory', type=Path, required=True)
p.add_argument('--game-port', type=int, action='append', required=True)
p.add_argument('--dll', type=Path, required=True)
p.add_argument('--seconds', type=int, default=90)
p.add_argument('--only-ports', action='store_true', help='Capture only specified ports, without game/STUN ranges')
a = p.parse_args()
assert 1 <= a.seconds <= 300
assert all(1 <= port <= 65535 for port in a.game_port)
root = a.output_directory.resolve()
root.mkdir(parents=True, exist_ok=True)
output = root / ('divert-' + datetime.datetime.now().strftime('%H%M%S') + '.jsonl')
status = root / 'divert-status.json'
handle = None
timer = None
count = 0
try:
    if not c.windll.shell32.IsUserAnAdmin():
        raise RuntimeError('Administrator rights required for read-only packet sniffing.')
    dll = c.WinDLL(str(a.dll.resolve()), use_last_error=True)
    dll.WinDivertOpen.argtypes = [c.c_char_p, c.c_int, c.c_short, c.c_ulonglong]
    dll.WinDivertOpen.restype = w.HANDLE
    dll.WinDivertRecv.argtypes = [w.HANDLE, c.c_void_p, w.UINT, c.POINTER(w.UINT), c.c_void_p]
    dll.WinDivertRecv.restype = w.BOOL
    dll.WinDivertShutdown.argtypes = [w.HANDLE, c.c_int]
    dll.WinDivertShutdown.restype = w.BOOL
    dll.WinDivertClose.argtypes = [w.HANDLE]
    dll.WinDivertClose.restype = w.BOOL
    ports = ' or '.join(f'udp.SrcPort == {port} or udp.DstPort == {port}' for port in a.game_port)
    # Remote 21xxx ports cover the NAT-side copy, whose local port can change.
    rule = ('udp and (' + ports + ' or (udp.SrcPort >= 21000 and udp.SrcPort <= 21999) or (udp.DstPort >= 21000 and udp.DstPort <= 21999) or udp.SrcPort == 3478 or udp.DstPort == 3478)').encode('ascii')
    if a.only_ports:
        rule = ('udp and (' + ports + ')').encode('ascii')
    # SNIFF | RECV_ONLY | NO_INSTALL: copy packets, never divert originals, never install a driver.
    handle = dll.WinDivertOpen(rule, 0, 30000, 1 | 4 | 16)
    if handle in (None, c.c_void_p(-1).value):
        handle = None
        raise c.WinError(c.get_last_error())
    freq = c.c_longlong()
    c.windll.kernel32.QueryPerformanceFrequency(c.byref(freq))
    base = c.c_longlong()
    c.windll.kernel32.QueryPerformanceCounter(c.byref(base))
    wall_base = time.time()
    timer = threading.Timer(a.seconds, lambda: dll.WinDivertShutdown(handle, 1))
    timer.start()
    status.write_text(json.dumps(dict(state='capturing', output=str(output), game_ports=a.game_port, mode='SNIFF|RECV_ONLY|NO_INSTALL')))
    packet = c.create_string_buffer(65535)
    address = c.create_string_buffer(80)
    length = w.UINT()
    last_flush = time.monotonic()
    with output.open('x') as f:
        while dll.WinDivertRecv(handle, packet, 65535, c.byref(length), address):
            data = packet[:length.value]
            if len(data) < 28 or data[0] >> 4 not in (4, 6):
                continue
            ticks, flags, iface = struct.unpack_from('<qQI', address.raw)
            if data[0] >> 4 == 4:
                ihl = (data[0]&15)*4
                src, dst = socket.inet_ntoa(data[12:16]), socket.inet_ntoa(data[16:20])
            else:
                if len(data) < 48 or data[6] != 17:
                    continue
                ihl = 40
                src, dst = socket.inet_ntop(socket.AF_INET6, data[8:24]), socket.inet_ntop(socket.AF_INET6, data[24:40])
            sport, dport, udp_len, _ = struct.unpack('!HHHH', data[ihl:ihl+8])
            rec = dict(at=wall_base+(ticks-base.value)/freq.value, read_at=time.time(), ticks=ticks, iface=iface, outbound=bool(flags&(1<<17)), impostor=bool(flags&(1<<19)), src=src, dst=dst, sport=sport, dport=dport, length=udp_len, payload_hash=hashlib.sha256(data[ihl+8:ihl+udp_len]).hexdigest())
            f.write(json.dumps(rec)+'\n')
            count += 1
            if time.monotonic()-last_flush > 0.3:
                f.flush()
                last_flush = time.monotonic()
        error = c.get_last_error()
        if error != 232:
            raise c.WinError(error)
    status.write_text(json.dumps(dict(state='complete', output=str(output), count=count)))
except Exception as e:
    status.write_text(json.dumps(dict(state='failed', error=str(e), output=str(output), count=count)))
finally:
    if timer:
        timer.cancel()
    if handle:
        dll.WinDivertClose(handle)
