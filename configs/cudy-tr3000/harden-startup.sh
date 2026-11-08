#!/bin/sh
set -eu
init=/opt/zapret2/init.d/openwrt/zapret2
if ! grep -q 'procd_set_param respawn' "$init"; then
    sed -i '/procd_set_param pidfile/a\
\tprocd_set_param respawn 3600 5 5\
\tprocd_set_param stdout 1\
\tprocd_set_param stderr 1' "$init"
fi
uci set passwall2.main.direct_dns_protocol=udp
uci set passwall2.main.loglevel=warn
uci set passwall2.main.log_node=0
uci commit passwall2
chmod 600 /etc/vpn-dns.json /etc/config/passwall2 /etc/vpn-host.txt
/etc/init.d/passwall2_server disable
/etc/init.d/zapret2 restart >/tmp/zapret-start.log 2>&1
/etc/init.d/passwall2 restart >/tmp/passwall-start.log 2>&1
/etc/init.d/zapret2 enable
/etc/init.d/vpn-dns enable
/etc/init.d/passwall2 enable
if [ -x /etc/init.d/https-dns-proxy ]; then
    /etc/init.d/https-dns-proxy enable
fi
if [ -x /etc/init.d/dns-select ]; then
    /etc/init.d/dns-select enable
fi
# Include local program/configuration files in a normal OpenWrt backup.
for path in /opt/zapret2/ /opt/xray/ /etc/vpn-dns.json /etc/vpn-host.txt /etc/init.d/vpn-dns /etc/init.d/zapret2 /etc/hotplug.d/iface/90-zapret2 /root/cudy-smoke.sh /root/cudy-forwarding-smoke.sh /etc/dns-select.conf /etc/init.d/dns-select; do
    grep -qxF "$path" /etc/sysupgrade.conf || echo "$path" >> /etc/sysupgrade.conf
done
