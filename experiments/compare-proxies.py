"""Alternate isolated local proxy profiles; never change the system profile."""
import argparse
import json
import math
from pathlib import Path
import socket
import statistics
import struct
import subprocess
import time

MODES = {"VLESS": 19482, "WARP-VLESS": 19487,
         "WireGuard": 19507, "WARP-WireGuard": 19506}


def read(sock, n):
    data = b""
    while len(data) < n:
        part = sock.recv(n - len(data))
        if not part:
            raise OSError("SOCKS closed")
        data += part
    return data


class UDP:
    def __init__(self, port):
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(("127.0.0.1", 0))
        self.udp.settimeout(2)
        self.control = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.control.sendall(b"\x05\x01\x00")
        assert read(self.control, 2) == b"\x05\x00"
        self.control.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("127.0.0.1")
                            + struct.pack("!H", self.udp.getsockname()[1]))
        assert read(self.control, 4) == b"\x05\x00\x00\x01"
        host = socket.inet_ntoa(read(self.control, 4))
        self.relay = (host if host != "0.0.0.0" else "127.0.0.1",
                      struct.unpack("!H", read(self.control, 2))[0])

    def query(self, index):
        tx = struct.pack("!H", index)
        dns = tx + struct.pack("!5H", 0x0100, 1, 0, 0, 0) + b"\x03www\x07example\x03com\x00\x00\x01\x00\x01"
        packet = b"\x00\x00\x00\x01" + socket.inet_aton("8.8.8.8") + struct.pack("!H", 53) + dns
        start = time.perf_counter()
        self.udp.sendto(packet, self.relay)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            result, _ = self.udp.recvfrom(4096)
            if result[:4] == b"\x00\x00\x00\x01" and result[10:12] == tx:
                if result[13] & 15:
                    raise OSError("DNS error response")
                return round((time.perf_counter() - start) * 1000, 2)
        raise TimeoutError("DNS response not received")

    def close(self):
        self.udp.close()
        self.control.close()


def fetch(mode, url, repeat=False):
    cmd = ["curl.exe", "--silent", "--show-error", "--ssl-revoke-best-effort",
           "--connect-timeout", "5", "--max-time", "15", "--proxy",
           f"socks5h://127.0.0.1:{MODES[mode]}", "--write-out", "%{json}\n",
           "--output", "NUL", url]
    if repeat:
        cmd += ["--output", "NUL", url]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=35)
    samples = []
    for line in p.stdout.splitlines():
        try:
            result = json.loads(line)
            samples.append({key: result.get(key) for key in
                            ("http_code", "time_connect", "time_appconnect",
                             "time_starttransfer", "time_total", "size_download",
                             "speed_download", "num_connects", "exitcode")})
        except ValueError:
            pass
    return {"mode": mode, "url": url, "exit": p.returncode, "samples": samples,
            "error": p.stderr.strip()}


def stats(values):
    values = sorted(values)
    return {"n": len(values), "median": round(statistics.median(values), 2),
            "p95": round(values[math.ceil(len(values) * .95) - 1], 2),
            "min": round(values[0], 2), "max": round(values[-1], 2)} if values else {"n": 0}


def main(path):
    report = {"started": time.time(), "udp": [], "web": [], "downloads": []}
    modes = list(MODES)
    clients = {mode: UDP(port) for mode, port in MODES.items()}
    try:
        for i in range(40):
            for mode in modes[i % 4:] + modes[:i % 4]:
                row = {"mode": mode, "round": i}
                try:
                    row["ms"] = clients[mode].query(2000 + i)
                except OSError as error:
                    row["error"] = str(error)
                report["udp"].append(row)
            if i % 10 == 9:
                print(f"UDP: {i+1}/40 per profile", flush=True)
    finally:
        for client in clients.values():
            client.close()
    path.write_text(json.dumps(report, indent=2))
    for i in range(6):
        for mode in modes[i % 4:] + modes[:i % 4]:
            for url in ("https://www.google.com/generate_204", "https://www.cloudflare.com/cdn-cgi/trace"):
                report["web"].append(fetch(mode, url, True))
        print(f"HTTPS: {i+1}/6 rounds", flush=True)
        path.write_text(json.dumps(report, indent=2))
    for i in range(3):
        for mode in modes[i % 4:] + modes[:i % 4]:
            row = fetch(mode, "https://speed.cloudflare.com/__down?bytes=10000000")
            report["downloads"].append(row)
            print(f"Download {i+1}/3: {mode}", flush=True)
        path.write_text(json.dumps(report, indent=2))
    summary = {}
    for mode in modes:
        udp = [r["ms"] for r in report["udp"] if r["mode"] == mode and "ms" in r]
        web = [r for r in report["web"] if r["mode"] == mode]
        successful = [r for r in web if r["exit"] == 0 and len(r["samples"]) == 2
                      and all(s["http_code"] in (200, 204) for s in r["samples"])]
        downloads = [r for r in report["downloads"] if r["mode"] == mode]
        summary[mode] = {"udp_ms": stats(udp), "udp_failed": 40 - len(udp),
                         "https_cold_ms": stats([r["samples"][0]["time_total"] * 1000 for r in successful]),
                         "https_best_ms": stats([min(s["time_total"] for s in r["samples"]) * 1000 for r in successful]),
                         "https_failed": len(web) - len(successful),
                         "download_mbps": [round(r["samples"][0]["speed_download"] * 8 / 1e6, 2)
                                           for r in downloads if r["exit"] == 0 and r["samples"][0]["size_download"] == 10000000]}
    report.update(summary=summary, finished=time.time())
    path.write_text(json.dumps(report, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    main(parser.parse_args().output)
