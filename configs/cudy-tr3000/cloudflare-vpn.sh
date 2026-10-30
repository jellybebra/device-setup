#!/bin/sh
# Use the official Cloudflare IPv4 ranges, not per-site DNS overrides.
# IPv6 forwarding is disabled in this router configuration.
set -eu
list=/opt/zapret2/ipset/cloudflare.txt
test -s "$list"
test "$(grep -c '/' "$list")" -eq 15
uci set passwall2.Cloudflare=shunt_rules
uci set passwall2.Cloudflare.remarks='Cloudflare official IPv4 ranges'
uci set passwall2.Cloudflare.group=Custom
uci set passwall2.Cloudflare.network=tcp,udp
uci set passwall2.Cloudflare.ip_list="$(cat "$list")"
uci set passwall2.split.Cloudflare=vpn
# Remove the temporary diagnostic pin while preserving unrelated overrides.
hosts=$(uci -q get passwall2.main.dns_hosts || true)
hosts=$(printf '%s\n' "$hosts" | awk 'NF && $1 != "macro.vzl0m.com"')
if [ -n "$hosts" ]; then
    uci set passwall2.main.dns_hosts="$hosts"
else
    uci -q delete passwall2.main.dns_hosts || true
fi
uci -q delete dhcp.macro_cloudflare || true
uci commit passwall2
uci commit dhcp
/etc/init.d/passwall2 restart >/tmp/passwall-cloudflare-restart.log 2>&1
/etc/init.d/dnsmasq restart
