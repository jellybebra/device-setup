#!/bin/sh
# Huawei WS7100-20 debug firmware: LAN bridges, IPv4 TCP rules + VLESS UDP.
D=/data/mvp
LAN=192.168.0.0/16 # Main 192.168.3.0/24 and Huawei guest 192.168.155.0/24
ADMIN=192.168.3.2/32
TUNPID=/tmp/mvp-tun.pid
DPIPID=/tmp/mvp-tpws.pid
TUN=mvpudp
BYPASS="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4"
PID=/tmp/mvp-xray.pid
LOCK=/tmp/mvp-watchdog.lock
export GOMEMLIMIT=40MiB GOGC=40 GOMAXPROCS=2
export SSL_CERT_FILE=$D/ca-certificates.crt XRAY_LOCATION_ASSET=$D

alive() {
    [ -f "$PID" ] || return 1
    p=$(cat "$PID")
    case "$p" in ''|*[!0-9]*) return 1;; esac
    [ -r "/proc/$p/cmdline" ] && grep -q "$D/xray" "/proc/$p/cmdline"
}
ready() {
    alive && netstat -lnt | grep -q ':12345 .*LISTEN' && netstat -lnt | grep -q '127.0.0.1:10810 .*LISTEN'
}
tun_alive() {
    [ -r "$TUNPID" ] || return 1
    t=$(cat "$TUNPID")
    case "$t" in ''|*[!0-9]*) return 1;; esac
    [ -r "/proc/$t/cmdline" ] && grep -q "$D/hev-socks5-tunnel" "/proc/$t/cmdline"
}
dpi_alive() {
    [ -r "$DPIPID" ] || return 1
    d=$(cat "$DPIPID")
    case "$d" in ''|*[!0-9]*) return 1;; esac
    [ -r "/proc/$d/cmdline" ] && grep -q "$D/tpws" "/proc/$d/cmdline"
}
stop_dpi() {
    if dpi_alive; then kill "$d"; fi
    rm -f "$DPIPID"
}
start_dpi() {
    "$D/tpws" --socks --bind-addr=127.0.0.1 --port=10809 --maxconn=256 --resolver-threads=2 --split-pos=1,midsld --disorder >/tmp/mvp-tpws.log 2>&1 &
    echo $! > "$DPIPID"
    echo 600 > "/proc/$(cat "$DPIPID")/oom_score_adj"
    sleep 1
}
stop_tun() {
    if tun_alive; then kill "$t"; fi
    rm -f "$TUNPID"
}
start_tun() {
    "$D/hev-socks5-tunnel" "$D/udp-tunnel.yml" >/tmp/mvp-tun.log 2>&1 &
    echo $! > "$TUNPID"
    echo 700 > "/proc/$(cat "$TUNPID")/oom_score_adj"
    sleep 1
    [ -f /proc/sys/net/ipv4/conf/$TUN/rp_filter ] && echo 0 > /proc/sys/net/ipv4/conf/$TUN/rp_filter
}
detach() {
    while iptables -D FORWARD -i br+ -s "$LAN" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
    while iptables -t mangle -D PREROUTING -i br+ -s "$LAN" -p udp -j MVP_UDP 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -i br+ -s "$LAN" -p tcp -j MVP_TCP 2>/dev/null; do :; done
    while ip rule del pref 27000 fwmark 0x42/0xff table 142 2>/dev/null; do :; done
    ip route flush table 142 2>/dev/null
    while iptables -D FORWARD -i br+ -o "$TUN" -s "$LAN" -p udp ! --dport 443 -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$TUN" -o br+ -d "$LAN" -p udp -j ACCEPT 2>/dev/null; do :; done
}
guard() {
    # The debug console must only be reachable from the selected PC.
    if ! iptables -n -L MVP_MGMT >/dev/null 2>&1; then
        iptables -N MVP_MGMT || return 1
        iptables -A MVP_MGMT -i br0 -s "$ADMIN" -j RETURN
        iptables -A MVP_MGMT -j DROP
    fi
    iptables -C INPUT -p tcp -m multiport --dports 23,3333 -j MVP_MGMT 2>/dev/null || iptables -I INPUT 1 -p tcp -m multiport --dports 23,3333 -j MVP_MGMT
    if ! iptables -n -L MVP_LAN >/dev/null 2>&1; then
        iptables -N MVP_LAN || return 1
        iptables -A MVP_LAN -i br+ -s "$LAN" -j RETURN
        iptables -A MVP_LAN -j DROP
    fi
    iptables -C INPUT -p tcp -m multiport --dports 10808,12345 -j MVP_LAN 2>/dev/null || iptables -I INPUT 1 -p tcp -m multiport --dports 10808,12345 -j MVP_LAN
    iptables -C INPUT -p udp --dport 10808 -j MVP_LAN 2>/dev/null || iptables -I INPUT 1 -p udp --dport 10808 -j MVP_LAN
}
attach() {
    if ! iptables -t nat -n -L MVP_TCP >/dev/null 2>&1; then
        iptables -t nat -N MVP_TCP || return 1
        for cidr in $BYPASS; do
            iptables -t nat -A MVP_TCP -d "$cidr" -j RETURN || return 1
        done
        iptables -t nat -A MVP_TCP -p tcp -j REDIRECT --to-ports 12345 || return 1
    fi
    if ! iptables -t mangle -n -L MVP_UDP >/dev/null 2>&1; then
        iptables -t mangle -N MVP_UDP || return 1
        for cidr in $BYPASS; do
            iptables -t mangle -A MVP_UDP -d "$cidr" -j RETURN || return 1
        done
        iptables -t mangle -A MVP_UDP -j MARK --set-xmark 0x42/0xff || return 1
    fi
    # Match voice ranges from the user's Windows Zapret EXP profile.
    iptables -t mangle -C MVP_UDP -p udp -m multiport --dports 19294:19344,50000:50100 -j RETURN 2>/dev/null || iptables -t mangle -I MVP_UDP 1 -p udp -m multiport --dports 19294:19344,50000:50100 -j RETURN
    # tpws handles TCP only: make browsers fall back from QUIC without delay.
    iptables -C FORWARD -i br+ -s "$LAN" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || iptables -I FORWARD 1 -i br+ -s "$LAN" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
    ip route replace default dev "$TUN" table 142 || return 1
    ip rule show | grep -q '27000:.*fwmark 0x42/0xff.*142' || ip rule add pref 27000 fwmark 0x42/0xff table 142
    iptables -C FORWARD -i br+ -o "$TUN" -s "$LAN" -p udp ! --dport 443 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i br+ -o "$TUN" -s "$LAN" -p udp ! --dport 443 -j ACCEPT
    iptables -C FORWARD -i "$TUN" -o br+ -d "$LAN" -p udp -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$TUN" -o br+ -d "$LAN" -p udp -j ACCEPT
    iptables -t mangle -C PREROUTING -i br+ -s "$LAN" -p udp -j MVP_UDP 2>/dev/null || iptables -t mangle -I PREROUTING 1 -i br+ -s "$LAN" -p udp -j MVP_UDP
    iptables -t nat -C PREROUTING -i br+ -s "$LAN" -p tcp -j MVP_TCP 2>/dev/null || iptables -t nat -I PREROUTING 1 -i br+ -s "$LAN" -p tcp -j MVP_TCP
}
stop_core() {
    detach
    stop_tun
    stop_dpi
    if alive; then kill "$p"; fi
    rm -f "$PID"
}
start_core() {
    stop_tun
    profile=$(cat "$D/active-profile" 2>/dev/null)
    case "$profile" in 1|2) ;; *) return 1;; esac
    "$D/xray" run -config "$D/profile-$profile.json" >/tmp/mvp-xray.log 2>&1 &
    echo $! > "$PID"
    echo 800 > "/proc/$(cat "$PID")/oom_score_adj"
}
watch() {
    if ! mkdir "$LOCK" 2>/dev/null; then
        old=$(cat "$LOCK/pid" 2>/dev/null)
        case "$old" in ''|*[!0-9]*) return;; esac
        if [ -r "/proc/$old/cmdline" ] && grep -q 'mvp-service.sh' "/proc/$old/cmdline"; then return; fi
        rm -f "$LOCK/pid"
        # BusyBox lacks rmdir; remove this exact, owned lock directory only.
        rm -r "$LOCK"
        mkdir "$LOCK" || return
    fi
    echo $$ > "$LOCK/pid"
    trap 'detach; rm -f "$LOCK/pid"; rm -r "$LOCK"; exit' TERM INT
    while :; do
        guard
        if [ -f "$D/enabled" ]; then
            if ! alive; then
                detach
                start_core
                sleep 20
            fi
            if [ -f "$D/enabled" ] && ready; then
                if ! dpi_alive; then detach; start_dpi; fi
                if ! tun_alive; then detach; start_tun; fi
                if dpi_alive && tun_alive && ip link show "$TUN" >/dev/null 2>&1; then attach; else detach; fi
            else
                detach
            fi
        else
            stop_core
        fi
        # Bound tmpfs logging without writing flash on every request.
        if [ -f /tmp/mvp-xray.log ] && [ "$(wc -c </tmp/mvp-xray.log)" -gt 131072 ]; then : >/tmp/mvp-xray.log; fi
        if [ -f /tmp/mvp-tun.log ] && [ "$(wc -c </tmp/mvp-tun.log)" -gt 65536 ]; then : >/tmp/mvp-tun.log; fi
        if [ -f /tmp/mvp-tpws.log ] && [ "$(wc -c </tmp/mvp-tpws.log)" -gt 65536 ]; then : >/tmp/mvp-tpws.log; fi
        sleep 3
    done
}
case "$1" in
    watch) watch;;
    on) echo 1 > "$D/enabled"; /bin/sh "$D/mvp-service.sh" watch >/tmp/mvp-watchdog.log 2>&1 & ;;
    off) rm -f "$D/enabled"; stop_core;;
    profile)
        case "$2" in 1|2) ;; *) echo 'Profile must be 1 or 2'; exit 1;; esac
        echo "$2" > "$D/active-profile.new"
        mv -f "$D/active-profile.new" "$D/active-profile"
        stop_core
        echo 1 > "$D/enabled"
        /bin/sh "$D/mvp-service.sh" watch >/tmp/mvp-watchdog.log 2>&1 &
        ;;
    status)
        echo 'Selected profile:'; cat "$D/active-profile"
        if [ -f "$D/enabled" ]; then echo 'Enabled'; else echo 'Disabled (direct Internet)'; fi
        if ready; then echo 'Xray ready'; else echo 'Xray not ready'; fi
        if iptables -t nat -C PREROUTING -i br+ -s "$LAN" -p tcp -j MVP_TCP 2>/dev/null; then echo 'TCP routing ACTIVE for Huawei LAN bridges (main and guest)'; else echo 'TCP routing inactive (direct Internet)'; fi
        if tun_alive && iptables -t mangle -C PREROUTING -i br+ -s "$LAN" -p udp -j MVP_UDP 2>/dev/null; then echo 'UDP routing ACTIVE (EXP voice ports bypass; other UDP uses Xray rules)'; else echo 'UDP routing inactive'; fi
        if dpi_alive; then echo 'Local tpws running (direct DPI bypass)'; else echo 'tpws not ready'; fi
        iptables -t nat -L MVP_TCP -n -v
        iptables -t mangle -L MVP_UDP -n -v
        ;;
    *) echo 'Usage: mvp-service.sh on|off|profile 1|profile 2|status|watch'; exit 1;;
esac
