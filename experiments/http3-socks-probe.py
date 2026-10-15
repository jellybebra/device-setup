"""Verify real HTTP/3 through SOCKS5 UDP (requires aioquic, no TCP fallback)."""
import argparse
import asyncio
import json
import socket
import struct

from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from aioquic.quic.events import HandshakeCompleted


class HTTP3(QuicConnectionProtocol):
    def __init__(self, connection):
        super().__init__(connection)
        self.http = H3Connection(connection)
        self.complete = asyncio.get_running_loop().create_future()
        self.body = bytearray()
        self.status = None
        self.alpn = None

    def quic_event_received(self, event):
        if isinstance(event, HandshakeCompleted):
            self.alpn = event.alpn_protocol
        for item in self.http.handle_event(event):
            if isinstance(item, HeadersReceived):
                self.status = dict(item.headers).get(b':status', b'').decode()
            if isinstance(item, DataReceived):
                self.body.extend(item.data)
            if isinstance(item, (HeadersReceived, DataReceived)) and item.stream_ended:
                if not self.complete.done():
                    self.complete.set_result(True)


class SocksPackets(asyncio.DatagramProtocol):
    def __init__(self, client, target, relay):
        self.client, self.target, self.relay = client, target, relay
        self.header = b'\0\0\0\1' + socket.inet_aton(target[0]) + struct.pack('!H', target[1])

    def connection_made(self, transport):
        self.transport = transport
        self.client.connection_made(self)

    def sendto(self, data, addr=None):
        self.transport.sendto(self.header + data, self.relay)

    def datagram_received(self, data, addr):
        if addr != self.relay or data[:3] != b'\0\0\0':
            return
        if data[3] == 1:
            offset = 10
        elif data[3] == 4:
            offset = 22
        elif data[3] == 3:
            offset = 7 + data[4]
        else:
            return
        self.client.datagram_received(data[offset:], self.target)

    def get_extra_info(self, name, default=None):
        return self.transport.get_extra_info(name, default)


async def probe(args):
    loop = asyncio.get_running_loop()
    target = ((await loop.getaddrinfo(args.host, 443, family=socket.AF_INET,
                                     type=socket.SOCK_DGRAM))[0][4][0], 443)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(('127.0.0.1', 0))
    udp.setblocking(False)
    writer = transport = client = None
    try:
        reader, writer = await asyncio.open_connection('127.0.0.1', args.port)
        writer.write(b'\5\1\0'); await writer.drain()
        assert await reader.readexactly(2) == b'\5\0', 'SOCKS authentication failed'
        writer.write(b'\5\3\0\1' + socket.inet_aton('127.0.0.1')
                     + struct.pack('!H', udp.getsockname()[1]))
        await writer.drain()
        assert await reader.readexactly(4) == b'\5\0\0\1', 'SOCKS UDP association failed'
        relay_ip = socket.inet_ntoa(await reader.readexactly(4))
        relay = (relay_ip if relay_ip != '0.0.0.0' else '127.0.0.1',
                 struct.unpack('!H', await reader.readexactly(2))[0])
        cfg = QuicConfiguration(is_client=True, alpn_protocols=['h3'],
                                server_name=args.host, max_datagram_size=1200)
        client = HTTP3(QuicConnection(configuration=cfg))
        transport, _ = await loop.create_datagram_endpoint(
            lambda: SocksPackets(client, target, relay), sock=udp)
        client.connect(target)
        await client.wait_connected()
        stream = client._quic.get_next_available_stream_id()
        client.http.send_headers(stream, [(b':method', b'GET'), (b':scheme', b'https'),
            (b':authority', args.host.encode()), (b':path', args.path.encode())], end_stream=True)
        client.transmit()
        await client.complete
        result = {'alpn': client.alpn, 'status': client.status, 'bytes': len(client.body),
                  'body': client.body.decode(errors='replace')[:2000]}
        print(json.dumps(result))
        assert client.alpn == 'h3' and client.status == '200', 'HTTP/3 request failed'
    finally:
        if client:
            client.close()
            await asyncio.sleep(.2)
        if transport:
            transport.close()
        else:
            udp.close()
        if writer:
            writer.close()
            await writer.wait_closed()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=19606)
    parser.add_argument('--host', default='www.cloudflare.com')
    parser.add_argument('--path', default='/cdn-cgi/trace')
    args = parser.parse_args()
    asyncio.run(asyncio.wait_for(probe(args), 25))
