#!/bin/sh
# Isolate router-originated diagnostic connections from PassWall2.
# Existing clients retain their current routes; zapret2 remains in the path.
set -eu
table=cudy_cf_probe
if nft list table inet "$table" >/dev/null 2>&1; then
    echo 'Probe table already exists; refusing to reuse it.' >&2
    exit 1
fi
capture=
cleanup() {
    [ -z "$capture" ] || { kill "$capture" 2>/dev/null || true; wait "$capture" 2>/dev/null || true; }
    nft delete table inet "$table" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
nft -f - <<'EOF'
table inet cudy_cf_probe {
    chain output {
        type route hook output priority -151; policy accept;
        tcp sport 45100-45149 meta mark set meta mark | 0xff counter
    }
}
EOF
tcpdump -ni eth0 -U -w /tmp/cudy-cf-probe.pcap 'tcp and (host 188.114.96.3 or host 188.114.97.3)' >/tmp/cudy-cf-capture.log 2>&1 &
capture=$!
sleep 1
for address in ${PROBE_IPS:-188.114.96.3 188.114.97.3 104.21.3.88}; do
    curl -4 -sS --noproxy '*' --local-port 45100-45149 \
        --resolve "macro.vzl0m.com:443:$address" --connect-timeout 5 --max-time 10 \
        -o /tmp/cudy-cf-probe-body \
        -w "DIRECT $address code=%{http_code} connect=%{time_connect} tls=%{time_appconnect} bytes=%{size_download} total=%{time_total}\n" \
        https://macro.vzl0m.com/ || true
done
for path in /assets/index-DZtJ5Qtl.js /assets/index-N5sASZbJ.css /cdn-cgi/trace; do
    curl -4 -fsS --noproxy '*' --local-port 45100-45149 \
        --resolve "macro.vzl0m.com:443:${ASSET_IP:-104.21.77.110}" \
        --connect-timeout 5 --max-time 15 -o /tmp/cudy-cf-probe-body \
        -w "DIRECT asset $path code=%{http_code} bytes=%{size_download} speed=%{speed_download} total=%{time_total}\n" \
        "https://macro.vzl0m.com$path" || true
done
sed -n '/^loc=/p;/^warp=/p' /tmp/cudy-cf-probe-body
for query in \
    'https://dns.google/resolve?name=macro.vzl0m.com&type=A' \
    'https://dns.google/resolve?name=macro.vzl0m.com&type=A&edns_client_subnet=8.8.8.0/24' \
    'https://cloudflare-dns.com/dns-query?name=macro.vzl0m.com&type=A'; do
    printf '\nDNS %s\n' "$query"
    curl -4 -fsS --noproxy '*' --local-port 45100-45149 \
        --resolve dns.google:443:8.8.8.8 --resolve cloudflare-dns.com:443:1.1.1.1 \
        --connect-timeout 4 --max-time 10 -H 'Accept: application/dns-json' "$query" || true
done
printf '\n'
kill "$capture"; wait "$capture" 2>/dev/null || true; capture=
tcpdump -nn -r /tmp/cudy-cf-probe.pcap 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0' 2>/dev/null | head -25
