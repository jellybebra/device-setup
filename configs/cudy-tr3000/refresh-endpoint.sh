#!/bin/sh
set -eu
base=/opt/zapret2/ipset
host=$(cat /etc/vpn-host.txt)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# This resolver is reached directly on the upstream LAN, even before VPN starts.
dig +short +time=2 +tries=2 @192.168.60.1 "$host" A |
    grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' > "$tmp" || true
if [ -s "$tmp" ]; then
    cp "$tmp" "$base/vpn-endpoints.txt"
fi
test -s "$base/vpn-endpoints.txt"
chmod 644 "$base/vpn-endpoints.txt"
cp "$base/vpn-endpoints.txt" "$base/zapret-ip-exclude.txt"
