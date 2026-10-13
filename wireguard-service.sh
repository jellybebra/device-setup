#!/usr/bin/env bash
# Persistent server interface, adopting the existing keys and peers without a reset.
set -euo pipefail
ROOT=/etc/device-setup/warp-wireguard
IFACE=wg-codex
MARK=codex-warp-wg
SUBNET=10.203.13.0/29
WAN=ens3
EXIT_IP=138.124.114.237
CHAIN=CWARPWG
[[ $EUID == 0 && -s "$ROOT/server.conf" && -f "$ROOT/managed" ]]

case "${1:-}" in
up)
  if ip link show "$IFACE" >/dev/null 2>&1; then
    [[ $(cat "/sys/class/net/$IFACE/ifalias") == "$MARK" ]] || { echo 'Foreign interface; refusing'; exit 1; }
  else
    ip link add "$IFACE" type wireguard
    ip link set dev "$IFACE" alias "$MARK"
  fi
  wg syncconf "$IFACE" "$ROOT/server.conf"
  ip address replace 10.203.13.1/29 dev "$IFACE"
  ip link set dev "$IFACE" mtu 1200 up
  sysctl -q -w net.ipv4.ip_forward=1
  iptables -w -N "$CHAIN" 2>/dev/null || iptables -w -S "$CHAIN" >/dev/null
  for net in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/3; do
    iptables -w -C "$CHAIN" -d "$net" -j DROP 2>/dev/null || iptables -w -I "$CHAIN" 1 -d "$net" -j DROP
  done
  iptables -w -C "$CHAIN" -s "$SUBNET" -o "$WAN" -j ACCEPT 2>/dev/null || iptables -w -A "$CHAIN" -s "$SUBNET" -o "$WAN" -j ACCEPT
  iptables -w -C "$CHAIN" -j DROP 2>/dev/null || iptables -w -A "$CHAIN" -j DROP
  iptables -w -C FORWARD -i "$IFACE" -m comment --comment "$MARK" -j "$CHAIN" 2>/dev/null || iptables -w -I FORWARD 1 -i "$IFACE" -m comment --comment "$MARK" -j "$CHAIN"
  iptables -w -C FORWARD -o "$IFACE" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$MARK" -j ACCEPT 2>/dev/null || iptables -w -I FORWARD 1 -o "$IFACE" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$MARK" -j ACCEPT
  iptables -w -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN" -m comment --comment "$MARK" -j SNAT --to-source "$EXIT_IP" 2>/dev/null || iptables -w -t nat -A POSTROUTING -s "$SUBNET" -o "$WAN" -m comment --comment "$MARK" -j SNAT --to-source "$EXIT_IP"
  ;;
status)
  ip -brief link show "$IFACE"
  wg show "$IFACE" listen-port
  ;;
*) echo 'Usage: wireguard-service.sh up|status'; exit 2 ;;
esac
