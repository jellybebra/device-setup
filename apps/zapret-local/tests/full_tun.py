"""Live macOS integration test. Takes ownership of the full system TUN for one ON/OFF cycle."""

import argparse
import concurrent.futures
import json
import socket
import subprocess
import threading
import time
from pathlib import Path
from urllib.parse import urlparse

SOCKET = "/var/run/com.jellybebra.zapret-cudy.sock"


def route(address, interface=None):
    args = ["/sbin/route", "-n", "get"]
    if interface:
        args += ["-ifscope", interface]
    text = subprocess.check_output(args + [address], text=True, timeout=5)
    return next(
        line.split(":", 1)[1].strip()
        for line in text.splitlines()
        if line.strip().startswith("interface:")
    )


def resolvers():
    config = subprocess.check_output(
        ["/usr/sbin/scutil", "--dns"], text=True, timeout=5
    )
    return [
        line.strip()
        for line in config.splitlines()
        if line.strip().startswith("nameserver[")
    ]


def fetch(url, proxy=None):
    args = [
        "/usr/bin/curl",
        "--disable",
        "--ipv4",
        "--silent",
        "--show-error",
        "--max-time",
        "6",
        "--output",
        "/dev/null",
        "--write-out",
        "%{http_code}",
    ]
    args += ["--noproxy", "", "--proxy", proxy] if proxy else ["--noproxy", "*"]
    result = subprocess.run(
        args + [url], timeout=8, capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise RuntimeError(f"{url}: {result.stderr.strip()}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument(
        "--management-proxy",
        required=True,
        help="Independent loopback proxy with a reachable peer excluded from TUN",
    )
    args = parser.parse_args()
    proxy = urlparse(args.management_proxy)
    if (
        proxy.scheme not in {"http", "socks5h"}
        or proxy.hostname != "127.0.0.1"
        or not proxy.port
    ):
        parser.error(
            "management proxy must be an explicit loopback HTTP or SOCKS5 endpoint"
        )
    node = json.loads(args.profile.read_bytes())
    target = "9.9.9.9"
    physical = route(target)
    if not physical.startswith("en"):
        raise RuntimeError("The system route is already owned by another tunnel")
    original_dns = resolvers()

    def management_ok():
        return fetch("https://api.openai.com/v1/models", args.management_proxy) in {
            "401",
            "403",
        }

    if not management_ok():
        raise RuntimeError("Independent management connection failed before the test")

    with socket.socket(socket.AF_UNIX) as control:
        control.settimeout(100)
        control.connect(SOCKET)
        with control.makefile("rb") as reader:

            def request(command, **fields):
                control.sendall(
                    json.dumps(dict(command=command, **fields)).encode() + b"\n"
                )
                reply = json.loads(reader.readline())
                if not reply["ok"]:
                    raise RuntimeError(reply["error"])
                return reply["running"]

            if request("status"):
                raise RuntimeError("Another Cudy session is already running")
            finished = threading.Event()

            def watchdog():
                deadline = time.monotonic() + 100
                while not finished.wait(1):
                    try:
                        if time.monotonic() < deadline and management_ok():
                            continue
                    except (OSError, RuntimeError, subprocess.TimeoutExpired):
                        pass
                    # EOF on the owning session makes the helper release its TUN and DNS.
                    control.shutdown(socket.SHUT_RDWR)
                    return

            watcher = threading.Thread(target=watchdog, daemon=True)
            watcher.start()
            try:
                with socket.socket() as available:
                    available.bind(("127.0.0.1", 0))
                    port = available.getsockname()[1]
                if not request(
                    "start",
                    node=node,
                    port=port,
                    selection={"strategy": "general-exp", "ipset": "cloudflare"},
                ):
                    raise RuntimeError("TUN did not start")
                captured = route(target)
                if (
                    not captured.startswith("utun")
                    or route(target, physical) != physical
                ):
                    raise RuntimeError("System and physical routes do not coexist")
                if resolvers()[0] != "nameserver[0] : 127.0.0.1":
                    raise RuntimeError("System resolver was not registered")
                with concurrent.futures.ThreadPoolExecutor(2) as pool:
                    codes = list(
                        pool.map(
                            fetch,
                            [
                                "https://www.apple.com/library/test/success.html",
                                "https://www.gstatic.com/generate_204",
                            ],
                        )
                    )
                if codes != ["200", "204"]:
                    raise RuntimeError(f"Unexpected HTTPS responses: {codes}")
                print(
                    f"ON: route {captured}, physical {physical}, system DNS on loopback, HTTPS {codes}"
                )
            finally:
                try:
                    if request("stop"):
                        raise RuntimeError("TUN stayed active after stop")
                finally:
                    finished.set()
                    watcher.join(timeout=9)
    for _ in range(30):
        if route(target) == physical and resolvers() == original_dns:
            print(f"OFF: route {physical} and original DNS restored")
            return
        time.sleep(0.1)
    raise RuntimeError("System routes or DNS were not restored")


if __name__ == "__main__":
    main()
