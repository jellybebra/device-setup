"""Forward a single aioquic HTTP/3 connection through a SOCKS UDP association on loopback."""

import asyncio
import contextlib
import io
import ipaddress
import os
import runpy
import select
import socket
import struct
import subprocess
import threading
from pathlib import Path


def http3(proxy, resolver, host, path):
    from aioquic.asyncio import connect
    from aioquic.h3.connection import H3_ALPN
    from aioquic.quic.configuration import QuicConfiguration

    script = Path(__file__).resolve().parents[3] / "configs/cudy-tr3000/quic-probe.py"
    client = runpy.run_path(os.fspath(script))["Client"]
    records = subprocess.check_output(
        [
            "dig",
            "+short",
            "+time=5",
            "+tries=1",
            "@127.0.0.1",
            "-p",
            str(resolver),
            host,
            "A",
        ],
        text=True,
    ).splitlines()
    ip = next(
        str(ipaddress.IPv4Address(a))
        for a in records
        if a and a[0].isdigit() and not a.endswith(".")
    )
    with (
        socket.create_connection(("127.0.0.1", proxy), timeout=5) as ctl,
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as relay,
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as edge,
    ):
        relay.bind(("127.0.0.1", 0))
        edge.bind(("127.0.0.1", 0))
        reader = ctl.makefile("rb")
        ctl.sendall(bytes.fromhex("050100"))
        if reader.read(2) != bytes.fromhex("0500"):
            raise OSError("SOCKS negotiation failed")
        ctl.sendall(
            bytes.fromhex("05030001")
            + socket.inet_aton("127.0.0.1")
            + struct.pack("!H", relay.getsockname()[1])
        )
        reply = reader.read(10)
        if reply[:4] != bytes.fromhex("05000001"):
            raise OSError("SOCKS UDP association failed")
        relay.connect((socket.inet_ntoa(reply[4:8]), struct.unpack("!H", reply[8:])[0]))
        prefix = (
            bytes.fromhex("00000001") + socket.inet_aton(ip) + struct.pack("!H", 443)
        )
        stop = threading.Event()

        def pump():
            source = None
            while not stop.is_set():
                ready, _, _ = select.select([relay, edge], [], [], 0.25)
                if edge in ready:
                    data, source = edge.recvfrom(65535)
                    relay.send(prefix + data)
                if relay in ready:
                    data = relay.recv(65535)
                    if source and data.startswith(prefix):
                        edge.sendto(data[len(prefix) :], source)

        thread = threading.Thread(target=pump, daemon=True)
        thread.start()

        async def fetch():
            cfg = QuicConfiguration(
                is_client=True, alpn_protocols=H3_ALPN, server_name=host
            )
            async with asyncio.timeout(15):
                async with connect(
                    "127.0.0.1",
                    edge.getsockname()[1],
                    configuration=cfg,
                    create_protocol=client,
                ) as c:
                    with contextlib.redirect_stdout(io.StringIO()):
                        await c.get(host, path)
                    return dict(c.headers).get(b":status", b"").startswith((b"2", b"3"))

        try:
            return asyncio.run(fetch())
        finally:
            stop.set()
            thread.join(1)
