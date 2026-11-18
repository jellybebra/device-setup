#!/bin/sh
# Runs on the router. Full GETs detect stalls beyond the first TLS records.
set -u
set --
if [ -n "${CUDY_TEST_HOST:-}" ]; then
    set -- "Cloudflare-site|https://$CUDY_TEST_HOST/"
fi
failed=0
x_home=$(mktemp) || exit 1
trap 'rm -f "$x_home"' EXIT
for item in \
    'YouTube|https://www.youtube.com/' \
    'YouTube-image|https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg' \
    'Discord|https://discord.com/' \
    'Discord-gateway|https://discord.com/api/v9/gateway' \
    'Instagram|https://www.instagram.com/' \
    'X|https://x.com/' \
    'Cloudflare|https://www.cloudflare.com/' \
    "$@" \
    'Telegram|https://web.telegram.org/'; do
    name=${item%%|*}; url=${item#*|}
    dest=/dev/null
    [ "$name" = X ] && dest=$x_home
    curl -4 -fsS --connect-timeout 4 --max-time 12 -o "$dest" \
        -w "$name code=%{http_code} bytes=%{size_download} seconds=%{time_total}\n" "$url" || failed=1
done
x_script=$(grep -oE 'https://abs[.]twimg[.]com/[a-zA-Z0-9_./-]+[.]js' "$x_home" | head -1)
if [ -n "$x_script" ]; then
    curl -4 -fsS --connect-timeout 4 --max-time 12 -o /dev/null \
        -w 'X-JavaScript code=%{http_code} bytes=%{size_download} seconds=%{time_total}\n' "$x_script" || failed=1
else
    echo 'X-JavaScript: no script URL found on the X home page' >&2
    failed=1
fi
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
