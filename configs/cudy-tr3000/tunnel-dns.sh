#!/bin/sh
# Quick Tunnel names change frequently. Bypass Xray's negative DNS cache for
# this suffix and use the existing direct, TLS-validated DoH resolver.
set -eu
line='server=/trycloudflare.com/127.0.0.1#15354'
grep -qxF "$line" /etc/dnsmasq.conf || echo "$line" >> /etc/dnsmasq.conf
uci set dhcp.@dnsmasq[0].nonegcache=1
uci commit dhcp
/etc/init.d/passwall2 restart >/tmp/tunnel-dns-passwall.log 2>&1
/etc/init.d/dnsmasq restart
