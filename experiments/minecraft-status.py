"""Query Minecraft Java status without logging in or changing the world."""
import argparse
import json
import socket
import struct


def varint(value):
    value &= 0xffffffff
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def exact(sock, length):
    data = bytearray()
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise EOFError('Server closed connection')
        data.extend(part)
    return bytes(data)


def readvarint(sock):
    value = 0
    for offset in range(0, 35, 7):
        byte = exact(sock, 1)[0]
        value |= (byte & 127) << offset
        if not byte & 128:
            return value
    raise ValueError('Invalid VarInt')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    parser.add_argument('--port', type=int, default=25565)
    args = parser.parse_args()
    host = args.host.encode()
    packet = b'\0' + varint(-1) + varint(len(host)) + host + struct.pack('!H', args.port) + b'\1'
    with socket.create_connection((args.host, args.port), timeout=8) as sock:
        sock.sendall(varint(len(packet)) + packet + b'\1\0')
        size = readvarint(sock)
        if not 0 < size < 1024 * 1024:
            raise ValueError('Unexpected packet size')
        if readvarint(sock) != 0:
            raise ValueError('Unexpected packet type')
        length = readvarint(sock)
        if not 0 < length <= size:
            raise ValueError('Unexpected JSON length')
        status = json.loads(exact(sock, length))
        print(json.dumps({'version': status.get('version'), 'online': status.get('players', {}).get('online'),
                          'max': status.get('players', {}).get('max')}, ensure_ascii=False))
