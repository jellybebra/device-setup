"""Integration check: frozen runtime, ownership pipe, port conflict; no real uplinks."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time


def main(binary):
    with tempfile.TemporaryDirectory(prefix='zapret-telegram-test-') as directory:
        root = Path(directory)
        with socket.socket() as socks, socket.socket() as port_selector:
            socks.bind(('127.0.0.1', 0))  # deliberately no listener: all uplinks fail closed
            port_selector.bind(('127.0.0.1', 0))
            port = port_selector.getsockname()[1]
            socks_port = socks.getsockname()[1]
            port_selector.close()
            (root / 'settings.json').write_text(json.dumps({'port': port, 'secret': secrets.token_hex(16)}))
            command = [str(binary), '--managed', '--state-dir', str(root), '--socks-port', str(socks_port)]
            env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'LANG': 'en_US.UTF-8'}
            subprocess.run([str(binary), '--self-test'], env=env, check=True)
            with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env) as child:
                try:
                    for _ in range(100):
                        assert child.poll() is None, child.stderr.read().decode()
                        if (root / 'ready.json').exists():
                            ready = json.loads((root / 'ready.json').read_text())
                            assert ready == {'pid': child.pid, 'port': port}
                            break
                        time.sleep(.05)
                    else:
                        raise AssertionError('Readiness timeout')
                    with socket.create_connection(('127.0.0.1', port), timeout=1):
                        pass
                    (root / 'ready.json').unlink()
                    conflict = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
                    try:
                        assert conflict.wait(timeout=5) != 0
                        assert not (root / 'ready.json').exists(), 'Port collision reported ready'
                    finally:
                        if conflict.poll() is None:
                            conflict.kill(); conflict.wait()
                        conflict.stdin.close(); conflict.stdout.close(); conflict.stderr.close()
                    child.stdin.close()
                    assert child.wait(timeout=5) == 0, 'Parent EOF did not stop the transport'
                finally:
                    if child.poll() is None:
                        child.kill(); child.wait()
            with socket.socket() as check:
                check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                check.bind(('127.0.0.1', port))
    print('PASS: standalone runtime, readiness, port conflict, parent EOF and released listener')


if __name__ == '__main__':
    main(Path(sys.argv[1]).resolve())
