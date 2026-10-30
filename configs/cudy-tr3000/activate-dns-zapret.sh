#!/bin/sh
set -eu
base=/opt/zapret2
vpn_host=$(cat /etc/vpn-host.txt)
mkdir -p "$base/ipset"
tar xzf /tmp/zapret-config.tar.gz -C "$base"
sed -i 's/\r$//' "$base"/config.* "$base"/ipset/*.txt
resolveip -4 -t 5 "$vpn_host" > "$base/ipset/vpn-endpoints.txt"
test -s "$base/ipset/vpn-endpoints.txt"
{
    echo "$vpn_host"
    printf '%s\n' telegram.org t.me telegram.me telegram.dog tdesktop.com telegra.ph telesco.pe
    printf '%s\n' openai.com chatgpt.com oaistatic.com oaiusercontent.com anthropic.com claude.ai
} > "$base/ipset/exclude-hosts.txt"
# Break the DNS bootstrap dependency: only the tunnel endpoint uses the WAN resolver.
uci set dhcp.@dnsmasq[0].noresolv=1
uci -q delete dhcp.@dnsmasq[0].server || true
uci add_list dhcp.@dnsmasq[0].server="/$vpn_host/192.168.60.1"
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#15353'
uci set dhcp.@dnsmasq[0].filter_aaaa=1
uci commit dhcp
/etc/init.d/dnsmasq restart
cp "$base/config.alt9" "$base/config"
ln -sf "$base/init.d/openwrt/zapret2" /etc/init.d/zapret2
cp "$base/init.d/openwrt/90-zapret2" /etc/hotplug.d/iface/90-zapret2
chmod 755 "$base/init.d/openwrt/zapret2" /etc/hotplug.d/iface/90-zapret2
chmod 755 "$base"/ipset/*.sh
. "$base/config"
"$base/nfq2/nfqws2" --dry-run --qnum=300 \
    --lua-init=@"$base/lua/zapret-lib.lua" \
    --lua-init=@"$base/lua/zapret-antidpi.lua" $NFQWS2_OPT
/etc/init.d/zapret2 start >/tmp/zapret-start.log 2>&1
sleep 2
pidof nfqws2
nft -t list table inet zapret2 | head -8
