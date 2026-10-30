"""Reboot the configured router once, then verify locally without internet."""
import argparse
import json
import logging
import time
from pathlib import Path
import paramiko
from recover_lan import connect, command

p = argparse.ArgumentParser()
p.add_argument('--state-dir', type=Path, required=True)
root = p.parse_args().state_dir
logging.basicConfig(filename=root / 'reboot-verify.log', level=logging.WARNING)
state = json.loads((root / 'stock-session.json').read_text())
key = paramiko.RSAKey.from_private_key_file(str(root / 'router-key'))
pin = (root / 'router-hostkey.pub').read_text()

def login():
    return connect('192.168.10.1', state['password'], key, pin)

t = login()
command(t, "nohup sh -c 'sleep 2; reboot' >/tmp/cudy-reboot.log 2>&1 </dev/null &")
t.close()
print('Reboot requested; waiting for the same SSH host key.', flush=True)
time.sleep(15)
deadline = time.monotonic() + 180
while time.monotonic() < deadline:
    try:
        t = login()
        break
    except (OSError, EOFError, paramiko.SSHException):
        time.sleep(4)
else:
    raise SystemExit('Router did not return within 195 seconds; see offline recovery notes.')
print('SSH restored. Waiting for startup services.', flush=True)
for _ in range(30):
    ready = command(t, 'pidof nfqws2 >/dev/null && test -s /tmp/etc/passwall2/acl/acl_default.json && nft list chain inet passwall2 PSW2_NAT >/dev/null 2>&1 && echo ready; true')
    if 'ready' in ready:
        break
    time.sleep(2)
result = command(t, 'sh /root/cudy-smoke.sh >/tmp/cudy-smoke-after-reboot.log 2>&1; result=$?; cat /tmp/cudy-smoke-after-reboot.log; echo smoke_exit=$result; uptime; ip -6 route show default; true')
(root / 'smoke-after-reboot.txt').write_text(result, newline='\n')
print(result)
t.close()
