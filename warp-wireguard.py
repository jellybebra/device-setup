"""Persistent Windows WARP -> WireGuard transport; no routes or v2rayN edits.

Credentials and copied binaries live beside this installed script, outside Git.
The scheduled task restarts this supervisor; a Windows job owns its children.
"""
import asyncio
import ctypes
from ctypes import wintypes
import datetime
import importlib.util
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import socket
import subprocess
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent
LOG = logging.getLogger("warp-wireguard")
NO_WINDOW = 0x08000000


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def own_process_tree():
    """Nested job: OS terminates all children even if the supervisor crashes."""
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    class Basic(ctypes.Structure):
        _fields_ = [("process_time", ctypes.c_longlong), ("job_time", ctypes.c_longlong),
                    ("flags", wintypes.DWORD), ("min_ws", ctypes.c_size_t),
                    ("max_ws", ctypes.c_size_t), ("active_limit", wintypes.DWORD),
                    ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD),
                    ("scheduling", wintypes.DWORD)]
    class Io(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in
                    ("reads", "writes", "others", "read_bytes", "write_bytes", "other_bytes")]
    class Extended(ctypes.Structure):
        _fields_ = [("basic", Basic), ("io", Io), ("process_memory", ctypes.c_size_t),
                    ("job_memory", ctypes.c_size_t), ("peak_process", ctypes.c_size_t),
                    ("peak_job", ctypes.c_size_t)]
    k.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    k.CreateJobObjectW.restype = wintypes.HANDLE
    k.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    k.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    k.GetCurrentProcess.restype = wintypes.HANDLE
    job = k.CreateJobObjectW(None, None)
    info = Extended()
    info.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not job or not k.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)):
        raise ctypes.WinError(ctypes.get_last_error())
    if not k.AssignProcessToJobObject(job, k.GetCurrentProcess()):
        raise ctypes.WinError(ctypes.get_last_error())
    # Keep this handle until process exit. Explicit CloseHandle would also kill us.
    return job


def save_status(state, **extra):
    target = ROOT / "status.json"
    temp = ROOT / "status.tmp"
    temp.write_text(json.dumps(dict(state=state, pid=os.getpid(),
                                   updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                   **extra), indent=2))
    temp.replace(target)


def rotating_log(name):
    logger = logging.getLogger(name)
    logger.setLevel(logging.INFO)
    handler = RotatingFileHandler(ROOT / (name + ".log"), maxBytes=2_000_000, backupCount=2)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    return logger


async def drain(process, name):
    logger = rotating_log(name)
    try:
        while line := await process.stdout.readline():
            logger.info("%s", line.decode("utf-8", errors="replace").rstrip())
    finally:
        for handler in logger.handlers[:]:
            handler.close()
            logger.removeHandler(handler)


async def session(settings, stop, support, shim):
    adapter = await asyncio.to_thread(support.physical_adapter, settings["preferred_interface"])
    loop = asyncio.get_running_loop()
    local = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    remote = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    processes, tasks = [], []
    children = {}
    try:
        # SO_EXCLUSIVEADDRUSE prevents silently sharing a UDP port with another service.
        local.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        local.bind(("127.0.0.1", settings["relay_port"]))
        local.setblocking(False)
        remote.setsockopt(socket.IPPROTO_IP, 31, socket.htonl(adapter["index"]))
        remote.bind((adapter["address"], 0))
        remote.connect((settings["warp_endpoint"], 443))
        remote.setblocking(False)
        for port in (settings["warp_socks_port"], settings["socks_port"]):
            with socket.socket() as check:
                check.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                check.bind(("127.0.0.1", port))
        client = None

        async def outgoing():
            nonlocal client
            while True:
                packet, client = await loop.sock_recvfrom(local, 65536)
                await loop.sock_sendall(remote, packet)

        async def incoming():
            while True:
                try:
                    packet = await loop.sock_recv(remote, 65536)
                    if client:
                        await loop.sock_sendto(local, packet, client)
                except ConnectionResetError:
                    await asyncio.sleep(.25)

        async def launch(name, args):
            process = await asyncio.create_subprocess_exec(
                *args, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT, creationflags=NO_WINDOW)
            processes.append(process)
            children[name] = process.pid
            tasks.append(asyncio.create_task(drain(process, name)))
            LOG.info("Started %s pid=%s", name, process.pid)
            return process

        tasks.extend(asyncio.create_task(f()) for f in (outgoing, incoming))
        await launch("usque", [str(ROOT / "usque.exe"), "-c", str(ROOT / "account.json"),
                     "socks", "-b", "127.0.0.1", "-p", str(settings["warp_socks_port"]),
                     "-P", str(settings["relay_port"]), "--always-reconnect", "--udp-timeout", "300s"])
        # Wait only for the local SOCKS listener, not a fixed startup delay.
        for _ in range(40):
            if stop.is_set():
                return
            try:
                reader, writer = await asyncio.wait_for(
                    asyncio.open_connection("127.0.0.1", settings["warp_socks_port"]), 1)
                writer.close()
                await writer.wait_closed()
                break
            except OSError:
                await asyncio.sleep(.25)
        else:
            raise OSError("WARP SOCKS listener did not start")
        tasks.append(asyncio.create_task(shim.session(SimpleNamespace(
            listen=settings["wg_relay_port"], proxy=settings["warp_socks_port"],
            target=settings["server"], port=settings["server_port"]))))
        await launch("sing-box", [str(ROOT / "sing-box.exe"), "run", "-c", str(ROOT / "wireguard.json")])
        save_status("connecting", adapter=adapter, children=children)

        async def monitor():
            failures, ticks = 0, 0
            while not stop.is_set():
                await asyncio.sleep(1)
                ticks += 1
                if any(p.returncode is not None for p in processes):
                    raise OSError("Transport child exited")
                if ticks % 15 == 0:
                    try:
                        await asyncio.to_thread(support.check_socks, settings["socks_port"])
                        failures = 0
                        save_status("healthy", adapter=adapter, children=children)
                    except OSError as error:
                        failures += 1
                        LOG.warning("Remote connection failed (%s/3): %s", failures, error)
                        if failures >= 3:
                            raise OSError("End-to-end connection unavailable") from error
                if ticks % 60 == 0:
                    current = await asyncio.to_thread(support.physical_adapter, settings["preferred_interface"])
                    if any(current[key] != adapter[key] for key in ("index", "address")):
                        raise OSError("Physical network changed")

        tasks.append(asyncio.create_task(monitor()))
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
        if not stop.is_set():
            raise OSError("Transport worker ended")
    finally:
        for process in reversed(processes):
            if process.returncode is None:
                process.terminate()
            try:
                await asyncio.wait_for(process.wait(), 5)
            except TimeoutError:
                process.kill()
                await process.wait()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        local.close()
        remote.close()


async def run(settings):
    support = load_module("warp_support", "warp-support.py")
    shim = load_module("warp_udp", "socks-udp-relay.py")
    stop = asyncio.Event()
    async def watch_stop():
        while not (ROOT / "stop.request").exists():
            await asyncio.sleep(1)
        stop.set()
    watcher = asyncio.create_task(watch_stop())
    try:
        while not stop.is_set():
            try:
                await session(settings, stop, support, shim)
            except Exception as error:
                LOG.exception("Reconnecting in five seconds")
                save_status("reconnecting", error=str(error))
                try:
                    await asyncio.wait_for(stop.wait(), 5)
                except TimeoutError:
                    pass
    finally:
        watcher.cancel()
        await asyncio.gather(watcher, return_exceptions=True)
        save_status("stopped")


def main():
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    k.CreateMutexW.restype = wintypes.HANDLE
    mutex = k.CreateMutexW(None, False, "Local\\DeviceSetupWarpWireGuard")
    if not mutex:
        raise ctypes.WinError(ctypes.get_last_error())
    if ctypes.get_last_error() == 183:
        return
    rotating_log("warp-wireguard")
    try:
        job = own_process_tree()
        (ROOT / "stop.request").unlink(missing_ok=True)
        settings = json.loads((ROOT / "settings.json").read_text(encoding="utf-8-sig"))
        LOG.info("Supervisor started pid=%s", os.getpid())
        asyncio.run(run(settings))
    except Exception:
        LOG.exception("Supervisor failed; scheduled task will retry")
        raise


if __name__ == "__main__":
    main()
