#!/bin/sh
# Temporary LAN client, without changing Windows routes or stopping v2rayN.
set -eu
ns=cudy-check
test ! -e /var/run/netns/$ns
test ! -e /sys/class/net/cudy-check-lan
test ! -d /etc/netns/$ns
if ip -4 addr show dev br-lan | grep -q '192.0.2.'; then
    echo 'Test subnet is already present; refusing to reuse it.' >&2
    exit 1
fi
cleanup() {
    ip netns del "$ns" 2>/dev/null || true
    ip link del cudy-check-lan 2>/dev/null || true
    ip addr del 192.0.2.1/30 dev br-lan 2>/dev/null || true
    rm -f /etc/netns/$ns/resolv.conf
    rmdir /etc/netns/$ns 2>/dev/null || true
}
trap cleanup EXIT INT TERM
ip netns add "$ns"
ip link add cudy-check-lan type veth peer name cudy-check-ns
ip link set cudy-check-ns netns "$ns"
ip link set cudy-check-lan master br-lan
ip link set cudy-check-lan up
ip addr add 192.0.2.1/30 dev br-lan
ip -n "$ns" link set lo up
ip -n "$ns" addr add 192.0.2.2/30 dev cudy-check-ns
ip -n "$ns" link set cudy-check-ns up
ip -n "$ns" route add default via 192.0.2.1
mkdir -p /etc/netns/$ns
echo 'nameserver 192.168.10.1' > /etc/netns/$ns/resolv.conf
failed=0
for item in \
    'YouTube|https://www.youtube.com/' \
    'YouTube-image|https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg' \
    'Discord|https://discord.com/' \
    'Instagram|https://www.instagram.com/' \
    'X|https://x.com/' \
    'Cloudflare|https://www.cloudflare.com/' \
    'Cloudflare-macro|https://macro.vzl0m.com/' \
    'Telegram|https://web.telegram.org/'; do
    name=${item%%|*}; url=${item#*|}
    ip netns exec "$ns" curl -4 -fsS --connect-timeout 8 --max-time 15 \
        -o /dev/null -w "LAN $name code=%{http_code} bytes=%{size_download} seconds=%{time_total}\n" "$url" || failed=1
done
printf 'LAN Cloudflare exit (direct RU expected): '
ip netns exec "$ns" curl -4 -fsS --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | sed -n '/^loc=/p'
exit "$failed"
