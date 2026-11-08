#!/bin/sh
# Route Notion and its image CDN through the existing VLESS node.
set -eu

test "$(uci get passwall2.split.protocol)" = '_shunt'
test "$(uci get passwall2.vpn.protocol)" = 'vless'
test -z "$(uci changes passwall2)"
umask 077
backup=$(mktemp -d /root/notion-routing-backup.XXXXXX)
cp -p /etc/config/passwall2 "$backup/passwall2"
echo "Backup: $backup/passwall2"

uci set passwall2.Notion=shunt_rules
uci set passwall2.Notion.remarks='Notion including images'
uci set passwall2.Notion.group='Custom'
uci set passwall2.Notion.network='tcp,udp'
uci set passwall2.Notion.domain_list='domain:notion.com
domain:notion.so
domain:notion.site
domain:notionusercontent.com
domain:notion-static.com'
uci set passwall2.split.Notion=vpn
uci commit passwall2
/etc/init.d/passwall2 restart >/tmp/passwall-notion-restart.log 2>&1
/etc/init.d/dnsmasq restart
