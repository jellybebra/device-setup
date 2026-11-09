"""Exercise the Cudy policy using only loopback listeners. No privileged helper or system TUN."""

import argparse
import concurrent.futures
import contextlib
import ipaddress
import json
import os
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def stun(proxy, resolver):
    """Send a new STUN binding through SOCKS UDP, keeping the association alive."""
    addresses = subprocess.check_output(
        [
            "dig",
            "+short",
            "+time=3",
            "+tries=1",
            "@127.0.0.1",
            "-p",
            str(resolver),
            "stun.l.google.com",
            "A",
        ],
        text=True,
    ).splitlines()
    ip = next(
        str(ipaddress.IPv4Address(a))
        for a in addresses
        if a and a[0].isdigit() and not a.endswith(".")
    )
    with (
        socket.create_connection(("127.0.0.1", proxy), timeout=5) as control,
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp,
    ):
        udp.settimeout(6)
        udp.bind(("127.0.0.1", 0))
        reader = control.makefile("rb")
        control.sendall(bytes.fromhex("050100"))
        if reader.read(2) != bytes.fromhex("0500"):
            return False
        control.sendall(
            bytes.fromhex("05030001")
            + socket.inet_aton("127.0.0.1")
            + struct.pack("!H", udp.getsockname()[1])
        )
        reply = reader.read(10)
        if reply[:4] != bytes.fromhex("05000001"):
            return False
        relay = (socket.inet_ntoa(reply[4:8]), struct.unpack("!H", reply[8:10])[0])
        transaction = os.urandom(12)
        packet = bytes.fromhex("000100002112a442") + transaction
        udp.sendto(
            bytes.fromhex("00000001")
            + socket.inet_aton(ip)
            + struct.pack("!H", 19302)
            + packet,
            relay,
        )
        response = udp.recvfrom(2048)[0]
        return (
            response[10:12] == bytes.fromhex("0101") and response[14:30] == packet[4:20]
        )


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--bin", type=Path, required=True)
    args.add_argument("--profile", type=Path, required=True)
    args.add_argument("--dpi-port", type=int, required=True)
    args.add_argument("--interface", required=True)
    args.add_argument(
        "--http3", action="store_true", help="Also check HTTP/3 using aioquic"
    )
    args = args.parse_args()
    binaries = args.bin.resolve()
    node = json.loads(args.profile.read_bytes())
    settings = node["settings"]
    host = (settings["vnext"][0] if "vnext" in settings else settings)["address"]
    try:
        endpoint = ipaddress.IPv4Address(host)
    except ipaddress.AddressValueError:
        endpoint = subprocess.check_output(
            [binaries / "cudy-dns", "-interface", args.interface, "-resolve", host],
            text=True,
        ).strip()
    with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as cleanup:
        tmp = Path(directory)
        case = {
            "node": node,
            "dpi": args.dpi_port,
            "endpoint": str(endpoint),
            "interface": args.interface,
        }
        with contextlib.ExitStack() as ports:
            for key in ["dns", "vless", "proxy", "resolver"]:
                sock = ports.enter_context(socket.socket())
                sock.bind(("127.0.0.1", 0))
                case[key] = sock.getsockname()[1]
        (tmp / "case.json").write_text(json.dumps(case))
        subprocess.run(
            [
                "cargo",
                "test",
                "--locked",
                "-p",
                "zapret-helper",
                "write_loopback_configs",
                "--",
                "--ignored",
            ],
            cwd=ROOT,
            check=True,
            env={**os.environ, "ZAPRET_LOOPBACK_DIR": directory},
        )
        log = cleanup.enter_context((tmp / "network.log").open("w+"))

        def start(argv, port):
            proc = subprocess.Popen(argv, stdout=log, stderr=log)

            def stop():
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

            cleanup.callback(stop)
            for _ in range(60):
                if proc.poll() is not None:
                    raise RuntimeError(f"{argv[0].name} could not start")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                        return
                except OSError:
                    time.sleep(0.05)
            raise RuntimeError(f"{argv[0].name} did not listen")

        start(
            [
                binaries / "cudy-dns",
                "-interface",
                args.interface,
                "-port",
                str(case["dns"]),
            ],
            case["dns"],
        )
        start([binaries / "xray", "run", "-c", tmp / "xray.json"], case["vless"])
        start([binaries / "sing-box", "run", "-c", tmp / "sing.json"], case["proxy"])

        def fetch(target):
            host, path = target
            records = subprocess.run(
                [
                    "dig",
                    "+short",
                    "+time=8",
                    "+tries=1",
                    "@127.0.0.1",
                    "-p",
                    str(case["resolver"]),
                    host,
                    "A",
                ],
                text=True,
                check=False,
                capture_output=True,
            ).stdout.splitlines()
            addresses = []
            for value in records:
                try:
                    addresses.append(ipaddress.IPv4Address(value))
                except ipaddress.AddressValueError:
                    pass
            for addr in addresses[:3]:
                # Mac applications generally connect to IP; the classifier sees TLS SNI.
                result = subprocess.run(
                    [
                        "curl",
                        "-sS",
                        "--noproxy",
                        "",
                        "--socks5",
                        f"127.0.0.1:{case['proxy']}",
                        "--max-time",
                        "8",
                        "--resolve",
                        f"{host}:443:{addr}",
                        "-o",
                        "/dev/null",
                        "-w",
                        "%{http_code} %{size_download}",
                        "https://" + host + path,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if result.returncode == 0 and result.stdout.startswith(("2", "3")):
                    print(host, result.stdout, flush=True)
                    return True
            print(
                host,
                (result.stderr.strip() or result.stdout) if addresses else "DNS failed",
                flush=True,
            )
            return False

        cases = [
            ("www.apple.com", "/"),
            ("www.youtube.com", "/generate_204"),
            ("i.ytimg.com", "/vi/jNQXAC9IVRw/hqdefault.jpg"),
            ("discord.com", "/api/v9/gateway"),
            ("x.com", "/"),
            ("abs.twimg.com", "/favicons/twitter.3.ico"),
            ("www.instagram.com", "/"),
            ("api.telegram.org", "/"),
            ("www.notion.so", "/"),
            ("cdn.platform.openai.com", "/cdn-cgi/trace"),
            ("svelte.dev", "/"),
        ]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            success = list(pool.map(fetch, cases))
        try:
            udp_ok = stun(case["proxy"], case["resolver"])
        except (OSError, StopIteration, ValueError) as err:
            print("STUN:", type(err).__name__)
            udp_ok = False
        print("STUN binding via UDP:", udp_ok)
        success.append(udp_ok)
        if args.http3:
            from loopback_quic import http3

            for host, path in [
                ("www.youtube.com", "/generate_204"),
                ("cdn.platform.openai.com", "/cdn-cgi/trace"),
            ]:
                try:
                    h3_ok = http3(case["proxy"], case["resolver"], host, path)
                except (
                    OSError,
                    TimeoutError,
                    StopIteration,
                    ValueError,
                    subprocess.CalledProcessError,
                ) as err:
                    print(host, "HTTP/3", type(err).__name__)
                    h3_ok = False
                print(host, "HTTP/3 response:", h3_ok)
                success.append(h3_ok)
        log.flush()
        # Report route tags only. Connections may contain private endpoint addresses.
        data = (tmp / "network.log").read_text()
        print(
            "Observed outbounds:",
            [k for k in ("direct", "dpi", "vless") if "[" + k + "]" in data],
        )
        return 0 if all(success) else 1


if __name__ == "__main__":
    raise SystemExit(main())
