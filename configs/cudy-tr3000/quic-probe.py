"""Small HTTP/3 diagnostic (requires aioquic); verifies certificates normally."""
import argparse
import asyncio

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.done = asyncio.get_running_loop().create_future()
        self.body = bytearray()
        self.headers = []

    def quic_event_received(self, event):
        for message in self.http.handle_event(event):
            if isinstance(message, HeadersReceived):
                self.headers.extend(message.headers)
            elif isinstance(message, DataReceived):
                self.body.extend(message.data)
            if getattr(message, 'stream_ended', False) and not self.done.done():
                self.done.set_result(None)

    async def get(self, host, path):
        stream = self._quic.get_next_available_stream_id()
        self.http.send_headers(stream, [
            (b':method', b'GET'), (b':scheme', b'https'),
            (b':authority', host.encode()), (b':path', path.encode()),
            (b'user-agent', b'HTTP3-route-diagnostic'),
        ], end_stream=True)
        self.transmit()
        await asyncio.wait_for(self.done, 15)
        print('HTTP/3 status:', dict(self.headers).get(b':status', b'?').decode())
        print(bytes(self.body).decode(errors='replace')[:1200])


async def main(args):
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.server_name = args.host
    async with asyncio.timeout(20):
        async with connect(args.host, 443, configuration=config,
                           create_protocol=Client, local_port=args.port) as client:
            await client.get(args.host, args.path)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='cdn.platform.openai.com')
    parser.add_argument('--path', default='/cdn-cgi/trace')
    parser.add_argument('--port', type=int, required=True)
    asyncio.run(main(parser.parse_args()))
