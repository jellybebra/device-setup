#!/bin/sh
# Keep OpenAI's additional CDN on the same VPN route as ChatGPT.
set -eu

test "$(uci get passwall2.split.protocol)" = '_shunt'
test -n "$(uci get passwall2.split.AI)"
test -z "$(uci changes passwall2)"
domains=$(uci get passwall2.AI.domain_list)
if printf '%s\n' "$domains" | grep -qxF 'full:cdn.openaimerge.com'; then
    echo 'OpenAI CDN route already configured.'
    exit 0
fi

umask 077
backup=$(mktemp -d /root/chatgpt-cdn-backup.XXXXXX)
cp -p /etc/config/passwall2 "$backup/passwall2"
echo "Backup: $backup/passwall2"
uci set passwall2.AI.domain_list="$domains
full:cdn.openaimerge.com"
uci commit passwall2
/etc/init.d/passwall2 restart >/tmp/passwall-chatgpt-cdn-restart.log 2>&1
/etc/init.d/dnsmasq restart
