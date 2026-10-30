#!/bin/sh
# Install direct-doh.config and dns-select.conf/init first.
set -eu
test -x /etc/init.d/https-dns-proxy
answer=$(dig @127.0.0.1 -p 15355 macro.vzl0m.com A +short +time=5 +tries=1)
printf '%s\n' "$answer" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
/etc/init.d/https-dns-proxy enable
/etc/init.d/dns-select enable
uci set passwall2.main.direct_dns_protocol=udp
uci set passwall2.main.direct_dns='127.0.0.1:15355'
uci -q delete passwall2.split.Cloudflare || true
# Preserve the VPN endpoint's separate WAN resolver and any domain-specific DNS.
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#15353' || true
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#15354' || true
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#15355' || true
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#15355'
uci commit passwall2
uci commit dhcp
/etc/init.d/passwall2 restart >/tmp/passwall-direct-doh.log 2>&1
/etc/init.d/dnsmasq restart
for path in /etc/dns-select.conf /etc/init.d/dns-select; do
    grep -qxF "$path" /etc/sysupgrade.conf || echo "$path" >> /etc/sysupgrade.conf
done
