"""Bounded, offline Windows recovery after installing stock-layout OpenWrt.

Run elevated BEFORE flashing. It waits for an explicit local signal, temporarily
addresses only the designated Ethernet adapter, verifies the router board over
SSH, restores LAN 192.168.10.1 and finally restores Windows DHCP. No flashing.
"""
import argparse
import ctypes
import json
import logging
import socket
import subprocess
import time
from pathlib import Path

import paramiko


def run(argv):
    result = subprocess.run(argv, capture_output=True, text=True, errors='replace')
    logging.info('%s -> %s: %s', argv, result.returncode, result.stdout.strip())
    if result.returncode:
        raise RuntimeError('Network configuration command failed')


def connect(host, password, key, expected_hostkey=None):
    sock = socket.create_connection((host, 22), timeout=3)
    transport = paramiko.Transport(sock)
    transport.banner_timeout = 4
    transport.start_client(timeout=5)
    if expected_hostkey is not None:
        observed = transport.get_remote_server_key()
        if observed.get_name() + ' ' + observed.get_base64() != expected_hostkey:
            transport.close()
            raise RuntimeError('SSH host key changed; authentication refused')
    try:
        transport.auth_publickey('root', key)
    except paramiko.AuthenticationException:
        try:
            transport.auth_none('root')
        except paramiko.AuthenticationException:
            transport.auth_password('root', password, fallback=False)
    return transport


def command(transport, text, input_data=None):
    channel = transport.open_session(timeout=8)
    channel.settimeout(180)
    channel.exec_command(text)
    if input_data is not None:
        channel.sendall(input_data.encode())
        channel.shutdown_write()
    output = channel.makefile('rb').read().decode(errors='replace')
    error = channel.makefile_stderr('rb').read().decode(errors='replace')
    rc = channel.recv_exit_status()
    if rc:
        raise RuntimeError('Router command failed: ' + error[:300])
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--adapter', default='Ethernet')
    args = parser.parse_args()
    root = args.state_dir
    logging.basicConfig(filename=root / 'recover-lan.log', level=logging.INFO,
                        format='%(asctime)s %(message)s')
    if not ctypes.windll.shell32.IsUserAnAdmin():
        raise SystemExit('Administrator privileges required for temporary IPv4 and DHCP restore')
    state = json.loads((root / 'stock-session.json').read_text())
    key = paramiko.RSAKey.from_private_key_file(str(root / 'router-key'))
    pubkey = (root / 'router-key.pub').read_text().strip()
    (root / 'recovery-ready').write_text('ready')
    logging.info('Ready; no network changes until recovery-go is created')
    deadline = time.monotonic() + 1800
    while not (root / 'recovery-go').exists():
        if time.monotonic() > deadline:
            return
        time.sleep(2)
    changed = False
    try:
        time.sleep(35)
        # A static address avoids dependence on DHCP renewal during firmware reboot.
        run(['netsh', 'interface', 'ipv4', 'set', 'address', f'name={args.adapter}',
             'source=static', 'address=192.168.1.2', 'mask=255.255.255.0', 'gateway=none'])
        changed = True
        deadline = time.monotonic() + 360
        transport = None
        while time.monotonic() < deadline:
            try:
                transport = connect('192.168.1.1', state['password'], key)
                break
            except (OSError, paramiko.SSHException):
                time.sleep(5)
        if transport is None:
            raise RuntimeError('OpenWrt SSH did not become ready at 192.168.1.1')
        board = json.loads(command(transport, 'ubus call system board'))
        (root / 'recovered-board.json').write_text(json.dumps(board, indent=2))
        if board.get('board_name') != 'cudy,tr3000-256mb-v1':
            raise RuntimeError('Wrong board: refusing any router changes')
        logging.info('Verified board: %s', board.get('model'))
        command(transport, "umask 077; mkdir -p /etc/dropbear; cat > /etc/dropbear/authorized_keys", pubkey + '\n')
        command(transport, 'passwd root', state['password'] + '\n' + state['password'] + '\n')
        command(transport, "uci set network.lan.ipaddr='192.168.10.1'; uci set network.lan.netmask='255.255.255.0'; uci set network.wan.proto='dhcp'; uci set system.@system[0].hostname='Cudy'; uci set system.@system[0].zonename='Europe/Moscow'; uci set system.@system[0].timezone='MSK-3'; uci commit network; uci commit system; sync")
        command(transport, "sh -c 'trap \"\" HUP; (sleep 2; /etc/init.d/network restart; /etc/init.d/dnsmasq restart) >/tmp/recover-network.log 2>&1 </dev/null &'")
        transport.close()
        logging.info('LAN restore requested')
        time.sleep(12)
    except Exception:
        logging.exception('Recovery failed')
        (root / 'recovery-failed').write_text('See recover-lan.log')
    finally:
        if changed:
            run(['netsh', 'interface', 'ipv4', 'set', 'address', f'name={args.adapter}', 'source=dhcp'])
            subprocess.run(['ipconfig', '/renew', args.adapter], capture_output=True, timeout=60)
            logging.info('Windows DHCP restored')
        (root / 'recovery-finished').write_text('finished')


if __name__ == '__main__':
    main()
