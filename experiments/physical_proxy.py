"""Task-local probes: bind external IPv4 sockets to a Windows/macOS adapter.

No system routes, DNS, firewall rules, or existing VPN processes are changed.
"""
import argparse
import asyncio
import json
import socket
import sys
import time


def physical_socket(kind, source, interface):
    if interface <= 0:
        raise ValueError("A positive physical interface index is required")
    if sys.platform not in ("win32", "darwin"):
        raise OSError("Physical interface binding is implemented for Windows/macOS only")
    sock = socket.socket(socket.AF_INET, kind)
    try:
        if sys.platform == "win32":
            # IP_UNICAST_IF expects an interface index in network byte order.
            sock.setsockopt(socket.IPPROTO_IP, 31, socket.htonl(interface))
        else:
            # Darwin IP_BOUND_IF takes a native int (bsd/netinet/in.h).
            sock.setsockopt(socket.IPPROTO_IP, 25, interface)
        sock.bind((source, 0))
        sock.setblocking(False)
        return sock
    except BaseException:
        sock.close()
        raise


async def connect(host, port, args):
    loop = asyncio.get_running_loop()
    addresses = await loop.getaddrinfo(host, port, family=socket.AF_INET,
                                       type=socket.SOCK_STREAM)
    error = None
    for address in addresses:
        sock = physical_socket(socket.SOCK_STREAM, args.source, args.interface)
        try:
            await asyncio.wait_for(loop.sock_connect(sock, address[4]), 8)
            return await asyncio.open_connection(sock=sock)
        except Exception as exc:
            sock.close()
            error = exc
    raise error or OSError("No IPv4 address")


async def pump(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (OSError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def http_proxy(reader, writer, args):
    try:
        header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        method, target, _ = header.split(b"\r\n", 1)[0].decode().split(" ", 2)
        if method != "CONNECT":
            writer.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        host, port = target.rsplit(":", 1)
        remote_reader, remote_writer = await connect(host, int(port), args)
        writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await writer.drain()
        await asyncio.gather(pump(reader, remote_writer), pump(remote_reader, writer))
    except Exception as exc:
        print(json.dumps({"proxy_error": str(exc)}), flush=True)
        writer.close()


async def tcp_relay(reader, writer, args):
    try:
        rr, rw = await connect(args.remote, args.remote_port, args)
        await asyncio.gather(pump(reader, rw), pump(rr, writer))
    except Exception as exc:
        print(json.dumps({"relay_error": str(exc)}), flush=True)
        writer.close()


async def udp_relay(args):
    loop = asyncio.get_running_loop()
    local = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    local.bind(("127.0.0.1", args.udp_port))
    local.setblocking(False)
    remote = physical_socket(socket.SOCK_DGRAM, args.source, args.interface)
    remote.connect((args.remote, args.remote_port))
    client = None
    counts = {"sent": 0, "received": 0, "sent_bytes": 0, "received_bytes": 0}

    async def outgoing():
        nonlocal client
        while True:
            data, client = await loop.sock_recvfrom(local, 65536)
            await loop.sock_sendall(remote, data)
            counts["sent"] += 1
            counts["sent_bytes"] += len(data)

    async def incoming():
        while True:
            try:
                data = await loop.sock_recv(remote, 65536)
                if client:
                    await loop.sock_sendto(local, data, client)
                    counts["received"] += 1
                    counts["received_bytes"] += len(data)
            except ConnectionResetError:
                print(json.dumps({"udp_icmp_reject": args.remote}), flush=True)
                await asyncio.sleep(.25)

    async def stats():
        while True:
            await asyncio.sleep(10)
            print(json.dumps({"udp": counts, "physical_source": remote.getsockname(),
                              "remote": [args.remote, args.remote_port]}), flush=True)

    await asyncio.gather(outgoing(), incoming(), stats())


async def main(args):
    proxy = await asyncio.start_server(lambda r, w: http_proxy(r, w, args),
                                       "127.0.0.1", args.proxy_port)
    relay = await asyncio.start_server(lambda r, w: tcp_relay(r, w, args),
                                       "127.0.0.1", args.tcp_port)
    print(json.dumps({"ready": True, "source": args.source,
                      "interface": args.interface, "remote": args.remote,
                      "ports": [args.proxy_port, args.tcp_port, args.udp_port]}), flush=True)
    async with proxy, relay:
        await asyncio.gather(proxy.serve_forever(), relay.serve_forever(), udp_relay(args))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--interface", required=True, type=int)
    parser.add_argument("--remote", default="162.159.198.2")
    parser.add_argument("--remote-port", default=443, type=int)
    parser.add_argument("--proxy-port", default=19481, type=int)
    parser.add_argument("--tcp-port", default=19484, type=int)
    parser.add_argument("--udp-port", default=19485, type=int)
    asyncio.run(main(parser.parse_args()))
