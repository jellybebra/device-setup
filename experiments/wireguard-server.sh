#!/usr/bin/env bash
# Isolated IPv4 test VPN. Does not modify VLESS, Docker, or the default route.
set -euo pipefail
ROOT=/opt/warp-wireguard-test
IFACE=wg-codex
PORT=51871
SUBNET=10.203.13.0/29
WAN=ens3
MARK=codex-warp-wg

cleanup() {
  if ip link show "$IFACE" >/dev/null 2>&1; then
    [[ $(cat "/sys/class/net/$IFACE/ifalias") == "$MARK" ]] || return 1
    ip link delete "$IFACE"
  fi
  while iptables -C FORWARD -i "$IFACE" -m comment --comment "$MARK" -j CWARPWG 2>/dev/null; do
    iptables -D FORWARD -i "$IFACE" -m comment --comment "$MARK" -j CWARPWG
  done
  while iptables -C FORWARD -o "$IFACE" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$MARK" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -o "$IFACE" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$MARK" -j ACCEPT
  done
  if iptables -S CWARPWG >/dev/null 2>&1; then
    iptables -F CWARPWG
    iptables -X CWARPWG
  fi
  while iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN" -m comment --comment "$MARK" -j SNAT --to-source 138.124.114.237 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$WAN" -m comment --comment "$MARK" -j SNAT --to-source 138.124.114.237
  done
}

case "${1:-}" in
down)
  [[ -f "$ROOT/owned-by-device-setup" ]] || { echo 'Missing ownership marker'; exit 1; }
  cleanup
  echo 'Test interface and its firewall rules removed.'
  exit 0
  ;;
up) ;;
*) echo 'Usage: wireguard-server.sh up|down'; exit 2 ;;
esac

command -v wg >/dev/null
[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]
if ip link show "$IFACE" >/dev/null 2>&1 || iptables -S CWARPWG >/dev/null 2>&1; then
  echo 'Test interface or chain already exists; inspect or stop it before retrying.'
  exit 1
fi
if ss -H -lun "sport = :$PORT" | read -r _; then
  echo 'Test UDP port is occupied.'
  exit 1
fi
if ip -4 route show | grep -q '10\.203\.13\.'; then
  echo 'Test subnet conflicts with an existing route.'
  exit 1
fi
umask 077
mkdir -p "$ROOT"
touch "$ROOT/owned-by-device-setup"
for name in server warp direct; do
  if [[ ! -f "$ROOT/$name.key" ]]; then wg genkey > "$ROOT/$name.key"; fi
  wg pubkey < "$ROOT/$name.key" > "$ROOT/$name.pub"
done
{
  printf '[Interface]\nPrivateKey = %s\nListenPort = %s\n' "$(cat "$ROOT/server.key")" "$PORT"
  printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.203.13.2/32\n' "$(cat "$ROOT/warp.pub")"
  printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.203.13.3/32\n' "$(cat "$ROOT/direct.pub")"
} > "$ROOT/server.conf"
python3 - <<'PY'
import json, pathlib
p=pathlib.Path('/opt/warp-wireguard-test')
data={'server_public_key':(p/'server.pub').read_text().strip(),
      'endpoint':'92.246.139.113','port':51871,
      'clients':{n:{'private_key':(p/(n+'.key')).read_text().strip(),
                    'address':ip} for n,ip in [('warp','10.203.13.2/32'),('direct','10.203.13.3/32')]}}
(p/'client-export.json').write_text(json.dumps(data))
PY
trap 'cleanup' ERR
ip link add "$IFACE" type wireguard
ip link set dev "$IFACE" alias "$MARK"
wg setconf "$IFACE" "$ROOT/server.conf"
ip address add 10.203.13.1/29 dev "$IFACE"
ip link set dev "$IFACE" mtu 1200 up
iptables -N CWARPWG
for net in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/3; do
  iptables -A CWARPWG -d "$net" -j DROP
done
iptables -A CWARPWG -s "$SUBNET" -o "$WAN" -j ACCEPT
iptables -A CWARPWG -j DROP
iptables -I FORWARD 1 -i "$IFACE" -m comment --comment "$MARK" -j CWARPWG
iptables -I FORWARD 1 -o "$IFACE" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$MARK" -j ACCEPT
iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$WAN" -m comment --comment "$MARK" -j SNAT --to-source 138.124.114.237
trap - ERR
echo "WireGuard ready: $IFACE, UDP $PORT, MTU 1200; two isolated test peers."
