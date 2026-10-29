import asyncio
import ssl
import unittest
from run import ZapretConnector


class ConnectorTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.servers = []

    async def asyncTearDown(self):
        for server in self.servers:
            server.close()
            await server.wait_closed()

    async def serve(self, handler):
        server = await asyncio.start_server(handler, '127.0.0.1', 0)
        self.servers.append(server)
        return server.sockets[0].getsockname()[1]

    async def test_remote_name_is_sent_to_socks_and_relay_survives_split_reply(self):
        async def socks(reader, writer):
            self.assertEqual(await reader.readexactly(3), b'\x05\x01\x00')
            writer.write(b'\x05\x00'); await writer.drain()
            self.assertEqual(await reader.readexactly(4), b'\x05\x01\x00\x03')
            size=(await reader.readexactly(1))[0]
            self.assertEqual(await reader.readexactly(size), b'kws2.web.telegram.org')
            self.assertEqual(await reader.readexactly(2), b'\x01\xbb')
            for byte in b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01':
                writer.write(bytes([byte])); await writer.drain(); await asyncio.sleep(0)
            writer.write(await reader.readexactly(4)); await writer.drain(); writer.close()
        port=await self.serve(socks)
        connect=ZapretConnector(asyncio.open_connection, lambda: port)
        reader,writer=await connect('kws2.web.telegram.org',443)
        writer.write(b'ping'); await writer.drain()
        self.assertEqual(await reader.readexactly(4),b'ping')
        writer.close(); await writer.wait_closed()

    async def test_socks_failure_closes_connection_without_direct_fallback(self):
        closed=asyncio.Event()
        async def socks(reader,writer):
            await reader.readexactly(3);writer.write(b'\x05\xff');await writer.drain()
            self.assertEqual(await reader.read(),b'');closed.set();writer.close()
        port=await self.serve(socks)
        with self.assertRaises(ConnectionError):
            await ZapretConnector(asyncio.open_connection,lambda:port)('must-not-resolve.invalid',443)
        await asyncio.wait_for(closed.wait(),1)

    async def test_cancel_during_handshake_closes_socks(self):
        started=asyncio.Event();closed=asyncio.Event()
        async def socks(reader,writer):
            await reader.readexactly(3);started.set()
            self.assertEqual(await reader.read(),b'');closed.set();writer.close()
        port=await self.serve(socks)
        task=asyncio.create_task(ZapretConnector(asyncio.open_connection,lambda:port)('example.com',443))
        await started.wait();task.cancel()
        with self.assertRaises(asyncio.CancelledError):await task
        await asyncio.wait_for(closed.wait(),1)

    async def test_tls_cannot_disable_hostname_verification(self):
        context=ssl.create_default_context();context.check_hostname=False
        async def forbidden(*args,**kwargs):self.fail('Must reject before any socket is opened')
        with self.assertRaises(ValueError):
            await ZapretConnector(forbidden,lambda:49949)('example.com',443,ssl=context)


if __name__=='__main__':unittest.main()
