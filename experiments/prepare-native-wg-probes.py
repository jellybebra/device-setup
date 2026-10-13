"""Generate private, server-only WireGuard probes; never a default-route profile.

Input is native-export.json from wireguard-native-peers.sh. On Windows, place
both input and output in an ACL-restricted folder outside any Git checkout.
On POSIX newly created files have mode 0600. Existing files are not overwritten.
"""
import argparse
import base64
import ipaddress
import json
import os
from pathlib import Path


def key(value):
    if not isinstance(value, str) or len(base64.b64decode(value, validate=True)) != 32:
        raise ValueError("Invalid WireGuard key")
    return value


def prepare(export, output, port):
    if not 1024 <= port <= 65535:
        raise ValueError("Relay port must be in 1024..65535")
    server = key(export['server_public_key'])
    profiles = []
    for name, expected in [('native-win', '10.203.13.4/32'),
                           ('native-mac', '10.203.13.5/32')]:
        client = export['clients'][name]
        address = str(ipaddress.ip_interface(client['address']))
        if address != expected:
            raise ValueError("Unexpected probe address")
        content = (f"[Interface]\nPrivateKey = {key(client['private_key'])}\n"
                   f"Address = {address}\nMTU = 1200\n\n"
                   f"[Peer]\nPublicKey = {server}\n"
                   f"AllowedIPs = 10.203.13.1/32\nEndpoint = 127.0.0.1:{port}\n"
                   "PersistentKeepalive = 25\n")
        profiles.append((output / (name + '-probe.conf'), content))
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any(path.exists() for path, _ in profiles):
        raise FileExistsError("Probe profile already exists; refusing to overwrite")
    created = []
    try:
        for path, content in profiles:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            created.append(path)
            with os.fdopen(fd, 'w', encoding='ascii', newline='\n') as stream:
                stream.write(content)
    except BaseException:
        for path in created:
            path.unlink()
        raise
    print("Created Windows/macOS server-only profiles; private keys were not printed.")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', type=Path, required=True)
    parser.add_argument('--output-directory', type=Path, required=True)
    parser.add_argument('--relay-port', type=int, default=19515)
    args = parser.parse_args()
    prepare(json.loads(args.export.read_text(encoding='utf-8-sig')),
            args.output_directory, args.relay_port)
