"""Task-local SSH helper. Credentials and host keys are never stored in Git."""
import argparse
import json
import shlex
from pathlib import Path

import paramiko
from recover_lan import connect, command


def transfer(transport, shell, source=None, destination=None):
    channel = transport.open_session(timeout=10)
    channel.settimeout(120)
    channel.exec_command(shell)
    if source:
        with source.open('rb') as stream:
            while chunk := stream.read(65536):
                channel.sendall(chunk)
        channel.shutdown_write()
    if destination:
        with destination.open('wb') as stream:
            while chunk := channel.recv(65536):
                stream.write(chunk)
    else:
        channel.makefile('rb').read()
    errors = channel.makefile_stderr('rb').read().decode(errors='replace')
    if channel.recv_exit_status():
        raise RuntimeError(errors)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--host', default='192.168.10.1')
    parser.add_argument('--trust-new-board', action='store_true')
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--command')
    actions.add_argument('--script', type=Path)
    actions.add_argument('--upload', nargs=2, metavar=('LOCAL', 'REMOTE'))
    actions.add_argument('--download', nargs=2, metavar=('REMOTE', 'LOCAL'))
    args = parser.parse_args()
    root = args.state_dir
    state = json.loads((root / 'stock-session.json').read_text())
    key = paramiko.RSAKey.from_private_key_file(str(root / 'router-key'))
    pin = root / 'router-hostkey.pub'
    if not pin.exists() and not args.trust_new_board:
        raise RuntimeError('No pinned host key; verify the router first')
    expected = pin.read_text() if pin.exists() and not args.trust_new_board else None
    transport = connect(args.host, state['password'], key, expected)
    try:
        observed = transport.get_remote_server_key()
        hostkey = observed.get_name() + ' ' + observed.get_base64()
        if not pin.exists() or pin.read_text() != hostkey:
            if not args.trust_new_board:
                raise RuntimeError('Unknown or changed host key; verify this firmware transition first')
            board = json.loads(command(transport, 'ubus call system board'))
            if board.get('board_name') != 'cudy,tr3000-256mb-v1':
                raise RuntimeError('Unexpected router board')
            pin.write_text(hostkey)
        if args.command:
            print(command(transport, args.command))
        elif args.script:
            print(command(transport, 'sh -s', args.script.read_text(encoding='utf-8')))
        elif args.upload:
            local, remote = args.upload
            transfer(transport, 'umask 077; cat > ' + shlex.quote(remote), source=Path(local))
            print('Uploaded', Path(local).name)
        else:
            remote, local = args.download
            transfer(transport, 'cat ' + shlex.quote(remote), destination=Path(local))
            print('Downloaded', Path(local).name)
    finally:
        transport.close()


if __name__ == '__main__':
    main()
