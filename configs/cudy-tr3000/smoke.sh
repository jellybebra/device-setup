#!/bin/sh
# Runs on the router. Full GETs detect stalls beyond the first TLS records.
set -u
failed=0
for item in \
    'YouTube|https://www.youtube.com/' \
    'YouTube-image|https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg' \
    'Discord|https://discord.com/' \
    'Discord-gateway|https://discord.com/api/v9/gateway' \
    'Instagram|https://www.instagram.com/' \
    'X|https://x.com/' \
    'X-JavaScript|https://abs.twimg.com/x-web/x-web/entry-client-logged-out-DKrfhWaR.js' \
    'Cloudflare|https://www.cloudflare.com/' \
    'Cloudflare-macro|https://macro.vzl0m.com/' \
    'Telegram|https://web.telegram.org/'; do
    name=${item%%|*}; url=${item#*|}
    curl -4 -fsS --connect-timeout 4 --max-time 12 -o /dev/null \
        -w "$name code=%{http_code} bytes=%{size_download} seconds=%{time_total}\n" "$url" || failed=1
done
printf 'Cloudflare exit (direct RU expected): '
curl -4 -fsS --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | sed -n '/^loc=/p'
printf 'VPN exit: '
curl -4 -fsS --max-time 10 --proxy http://127.0.0.1:18080 \
    https://www.cloudflare.com/cdn-cgi/trace | sed -n '/^loc=/p'
printf 'nfqws2 PID: '; pidof nfqws2 || failed=1
printf 'Xray PIDs: '; pidof xray || failed=1
cat /proc/net/netfilter/nfnetlink_queue
free -m
exit "$failed"
