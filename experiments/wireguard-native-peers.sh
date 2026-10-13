#!/usr/bin/env bash
# Add independent Windows/macOS peers to the task's existing interface, without restart.
set -euo pipefail
ROOT=/opt/warp-wireguard-test
if [[ -f /etc/device-setup/warp-wireguard/managed ]]; then
  echo 'Use the permanent server configuration for peer changes; this experiment is retired.'
  exit 1
fi
IFACE=wg-codex
[[ -f "$ROOT/owned-by-device-setup" ]]
[[ $(cat "/sys/class/net/$IFACE/ifalias") == codex-warp-wg ]]
[[ $(wg show "$IFACE" listen-port) == 51871 ]]
umask 077
for name in native-win native-mac; do
  [[ -f "$ROOT/$name.key" ]] || wg genkey > "$ROOT/$name.key"
  wg pubkey < "$ROOT/$name.key" > "$ROOT/$name.pub"
done
# Refuse to take an address assigned to any different peer.
python3 - <<'PY'
import pathlib, subprocess
p=pathlib.Path('/opt/warp-wireguard-test')
rows=subprocess.check_output(['wg','show','wg-codex','allowed-ips'],text=True).splitlines()
for name,addr in [('native-win','10.203.13.4/32'),('native-mac','10.203.13.5/32')]:
    key=(p/(name+'.pub')).read_text().strip()
    for row in rows:
        peer,ips=row.split('\t')
        if addr in ips.replace(',', ' ').split() and peer != key:
            raise SystemExit('Native peer address already belongs to another key')
PY
wg set "$IFACE" peer "$(cat "$ROOT/native-win.pub")" allowed-ips 10.203.13.4/32
wg set "$IFACE" peer "$(cat "$ROOT/native-mac.pub")" allowed-ips 10.203.13.5/32
wg showconf "$IFACE" > "$ROOT/server.conf"
python3 - <<'PY'
import json,pathlib
p=pathlib.Path('/opt/warp-wireguard-test')
d={'server_public_key':(p/'server.pub').read_text().strip(),
   'endpoint':'92.246.139.113','port':51871,
   'clients':{name:{'private_key':(p/(name+'.key')).read_text().strip(),'address':addr}
              for name,addr in [('native-win','10.203.13.4/32'),('native-mac','10.203.13.5/32')]}}
(p/'native-export.json').write_text(json.dumps(d))
PY
echo 'Separate native peers added; existing peers and VLESS were not restarted.'
