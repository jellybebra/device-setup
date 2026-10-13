"""Fixed UDP destination via SOCKS, declaring the actual UDP source port.

Works around usque 4.2.1 rejecting sing-box's zero-source UDP ASSOCIATE.
All local listeners are loopback-only; packets remain encrypted WireGuard.
"""
import argparse
import asyncio
import socket
import struct


async def session(args):
    loop = asyncio.get_running_loop()
    local = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    writer = None
    tasks = []
    try:
        local.bind(("127.0.0.1", args.listen))
        udp.bind(("127.0.0.1", 0))
        local.setblocking(False)
        udp.setblocking(False)
        reader, writer = await asyncio.open_connection("127.0.0.1", args.proxy)
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        if await reader.readexactly(2) != b"\x05\x00":
            raise OSError("SOCKS negotiation failed")
        writer.write(b"\x05\x03\x00\x01" + socket.inet_aton("127.0.0.1")
                     + struct.pack("!H", udp.getsockname()[1]))
        await writer.drain()
        reply = await reader.readexactly(4)
        if reply != b"\x05\x00\x00\x01":
            raise OSError("Expected IPv4 SOCKS UDP relay")
        relay = (socket.inet_ntoa(await reader.readexactly(4)),
                 struct.unpack("!H", await reader.readexactly(2))[0])
        udp.connect(relay)
        header = b"\x00\x00\x00\x01" + socket.inet_aton(args.target) + struct.pack("!H", args.port)
        client = None

        async def send():
            nonlocal client
            while True:
                packet, client = await loop.sock_recvfrom(local, 65536)
                await loop.sock_sendall(udp, header + packet)

        async def receive():
            while True:
                packet = await loop.sock_recv(udp, 65536)
                if client and packet.startswith(header):
                    await loop.sock_sendto(local, packet[len(header):], client)

        async def monitor():
            await reader.read(1)
            raise OSError("SOCKS control connection closed")

        print(f"Ready: UDP 127.0.0.1:{args.listen} -> SOCKS {args.proxy} -> {args.target}:{args.port}", flush=True)
        tasks = [asyncio.create_task(f()) for f in (send, receive, monitor)]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if writer:
            writer.close()
        local.close()
        udp.close()


async def main(args):
    while True:
        try:
            await session(args)
        except OSError as error:
            print(f"Reconnecting: {error}", flush=True)
            await asyncio.sleep(2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, default=19505)
    parser.add_argument("--proxy", type=int, default=19501)
    parser.add_argument("--target", default="92.246.139.113")
    parser.add_argument("--port", type=int, default=51871)
    asyncio.run(main(parser.parse_args()))
