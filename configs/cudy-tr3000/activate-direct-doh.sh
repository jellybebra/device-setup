#!/bin/sh
# Install direct-doh.config, dns-direct.conf and dns-select.conf/init first.
set -eu
test -x /etc/init.d/https-dns-proxy
/etc/init.d/https-dns-proxy restart
/etc/init.d/dns-select restart
vpn_host=$(cat /etc/vpn-host.txt)
for port in 15354 15356 15355; do
    ready=0
    for attempt in 1 2 3; do
        if dig @127.0.0.1 -p "$port" "$vpn_host" A +short +time=4 +tries=1 |
            grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then ready=1; break; fi
        sleep 1
    done
    [ "$ready" = 1 ] || { echo "DNS check failed on port $port" >&2; exit 1; }
done
/etc/init.d/https-dns-proxy enable
/etc/init.d/dns-select enable
uci set passwall2.main.direct_dns_protocol=udp
uci set passwall2.main.direct_dns='127.0.0.1:15355'
uci -q delete passwall2.split.Cloudflare || true
# Remove only the old endpoint override and superseded default resolvers.
uci -q del_list dhcp.@dnsmasq[0].server="/$vpn_host/192.168.60.1" || true
uci set dhcp.@dnsmasq[0].noresolv=1
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#15353' || true
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#15354' || true
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#15355' || true
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#15355'
uci commit passwall2
uci commit dhcp
sed -i 's|^server=/trycloudflare\.com/127\.0\.0\.1#15354$|server=/trycloudflare.com/127.0.0.1#15355|' /etc/dnsmasq.conf
/etc/init.d/dnsmasq restart
/etc/init.d/passwall2 restart >/tmp/passwall-direct-doh.log 2>&1
/etc/init.d/dnsmasq restart
for path in /etc/dns-select.conf /etc/dns-direct.conf /etc/init.d/dns-select; do
    grep -qxF "$path" /etc/sysupgrade.conf || echo "$path" >> /etc/sysupgrade.conf
done
