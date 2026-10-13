"""Keep a local usque SOCKS hop alive, with MASQUE bound to a physical NIC.

Windows only. Credentials live in the installation directory, outside Git.
This does not change system routes, DNS, or the active v2rayN profile.
"""
import asyncio
import ctypes
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import socket
import struct
import subprocess

ROOT = Path(__file__).resolve().parent
LOG = logging.getLogger("warp-bridge")
NO_WINDOW = 0x08000000


def physical_adapter(preferred):
    # Only hardware adapters with a default route qualify; never select a TUN.
    command = r"""
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$items = foreach ($a in Get-NetAdapter -Physical | Where-Object Status -eq 'Up') {
  $r = Get-NetRoute -AddressFamily IPv4 -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
  $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | Where-Object { $_.AddressState -eq 'Preferred' -and -not $_.SkipAsSource -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
  if ($r -and $ip) {
    $iface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $a.ifIndex
    [pscustomobject]@{alias=$a.Name; index=$a.ifIndex; address=$ip.IPAddress; metric=($r.RouteMetric + $iface.InterfaceMetric)}
  }
}
ConvertTo-Json -InputObject @($items) -Compress
"""
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
        capture_output=True, timeout=30, creationflags=NO_WINDOW, check=True,
    )
    adapters = json.loads(result.stdout.decode("utf-8-sig"))
    if not adapters:
        raise OSError("No connected physical IPv4 adapter with a default route")
    return min(adapters, key=lambda a: (a["alias"] != preferred, a["metric"]))


def recv_exact(sock, count):
    result = b""
    while len(result) < count:
        data = sock.recv(count - len(result))
        if not data:
            raise OSError("SOCKS connection closed")
        result += data
    return result


def check_socks(port):
    # A successful CONNECT verifies the remote MASQUE path, not just a listener.
    with socket.create_connection(("127.0.0.1", port), timeout=8) as sock:
        sock.sendall(b"\x05\x01\x00")
        if recv_exact(sock, 2) != b"\x05\x00":
            raise OSError("SOCKS authentication negotiation failed")
        host = b"www.cloudflare.com"
        sock.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", 443))
        reply = recv_exact(sock, 4)
        if reply[:2] != b"\x05\x00":
            raise OSError("SOCKS CONNECT failed")


async def session(settings, stop):
    adapter = await asyncio.to_thread(physical_adapter, settings["preferred_interface"])
    loop = asyncio.get_running_loop()
    local = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    remote = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    process = None
    tasks = []
    try:
        local.bind(("127.0.0.1", settings["relay_port"]))
        local.setblocking(False)
        remote.setsockopt(socket.IPPROTO_IP, 31, socket.htonl(adapter["index"]))
        remote.bind((adapter["address"], 0))
        remote.setblocking(False)
        remote.connect((settings["endpoint"], 443))
        # Do not launch a second instance over an existing SOCKS service.
        with socket.socket() as port_check:
            port_check.bind(("127.0.0.1", settings["socks_port"]))
        client = None

        async def outgoing():
            nonlocal client
            while True:
                data, client = await loop.sock_recvfrom(local, 65536)
                await loop.sock_sendall(remote, data)

        async def incoming():
            while True:
                data = await loop.sock_recv(remote, 65536)
                if client:
                    await loop.sock_sendto(local, data, client)

        log_path = ROOT / "usque.log"
        if log_path.exists() and log_path.stat().st_size > 5_000_000:
            log_path.replace(ROOT / "usque.previous.log")
        with log_path.open("ab", buffering=0) as output:
            process = subprocess.Popen(
                [settings["usque"], "-c", settings["account"], "l4-socks",
                 "-b", "127.0.0.1", "-p", str(settings["socks_port"]),
                 "-P", str(settings["relay_port"]), "--system-dns"],
                stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                creationflags=NO_WINDOW,
            )
        LOG.info("Started usque pid=%s via %s (%s), SOCKS=%s", process.pid,
                 adapter["alias"], adapter["address"], settings["socks_port"])

        async def monitor():
            failures = 0
            ticks = 0
            while not stop.is_set():
                await asyncio.sleep(1)
                ticks += 1
                if process.poll() is not None:
                    raise OSError(f"usque exited: {process.returncode}")
                if ticks % 15 == 0:
                    try:
                        await asyncio.to_thread(check_socks, settings["socks_port"])
                        if failures or ticks == 15:
                            LOG.info("SOCKS remote connection healthy")
                        failures = 0
                    except OSError as exc:
                        failures += 1
                        LOG.warning("Health check %s/3: %s", failures, exc)
                        if failures >= 3:
                            raise OSError("Remote connection failed three checks") from exc
                if ticks % 60 == 0:
                    current = await asyncio.to_thread(physical_adapter, settings["preferred_interface"])
                    if any(current[key] != adapter[key] for key in ("index", "address")):
                        raise OSError("Physical adapter changed; reconnecting")

        tasks = [asyncio.create_task(f()) for f in (outgoing, incoming, monitor)]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                await asyncio.to_thread(process.wait, 5)
            except subprocess.TimeoutExpired:
                process.kill()
                await asyncio.to_thread(process.wait)
        local.close()
        remote.close()


async def run(settings):
    stop = asyncio.Event()

    async def watch_stop():
        while not (ROOT / "stop.request").exists():
            await asyncio.sleep(1)
        stop.set()

    watcher = asyncio.create_task(watch_stop())
    try:
        while not stop.is_set():
            try:
                await session(settings, stop)
            except Exception:
                LOG.exception("Connection interrupted; retrying in five seconds")
                try:
                    await asyncio.wait_for(stop.wait(), timeout=5)
                except TimeoutError:
                    pass
    finally:
        watcher.cancel()
        LOG.info("Stopped")


def main():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateMutexW(None, False, "Local\\DeviceSetupWarpBridge")
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    if ctypes.get_last_error() == 183:
        kernel.CloseHandle(handle)
        return
    handler = RotatingFileHandler(ROOT / "bridge.log", maxBytes=2_000_000, backupCount=2)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    LOG.addHandler(handler)
    LOG.setLevel(logging.INFO)
    try:
        (ROOT / "stop.request").unlink(missing_ok=True)
        settings = json.loads((ROOT / "bridge-settings.json").read_text(encoding="utf-8-sig"))
        LOG.info("Supervisor started pid=%s", os.getpid())
        asyncio.run(run(settings))
    except Exception:
        LOG.exception("Supervisor stopped unexpectedly")
        raise
    finally:
        kernel.CloseHandle(handle)


if __name__ == "__main__":
    main()
