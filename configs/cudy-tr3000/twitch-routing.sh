#!/bin/sh
# Match the V2DPI playback profile. The site and the video CDN use the direct default.
set -eu

test "$(uci get passwall2.main.node)" = split
test "$(uci get passwall2.split.protocol)" = _shunt
test "$(uci get passwall2.split.default_node)" = _direct
# Reuse the configured VLESS exit, including installations with the provider chain.
node=$(uci get passwall2.split.AI)
test "$(uci get "passwall2.$node.protocol")" = vless
group=$(uci get passwall2.split.shunt_group)
test -z "$(uci changes passwall2)"
trap 'uci revert passwall2' EXIT
domains='full:usher.ttvnw.net
full:gql.twitch.tv'
uci set passwall2.TwitchPlayback=shunt_rules
uci set passwall2.TwitchPlayback.remarks='Twitch playback API and playlist'
uci set "passwall2.TwitchPlayback.group=$group"
uci set passwall2.TwitchPlayback.network='tcp,udp'
uci set passwall2.TwitchPlayback.domain_list="$domains"
uci set "passwall2.split.TwitchPlayback=$node"
# gql.twitch.tv and www.twitch.tv share addresses. Give only the two API
# names separate destinations so PassWall's direct-IP cache can distinguish them.
uci set passwall2.split.fakedns=1
uci set passwall2.split.TwitchPlayback_fakedns=1
[ -n "$(uci changes passwall2)" ] || exit 0
umask 077
backup=$(mktemp -d /root/twitch-routing-backup.XXXXXX)
cp -p /etc/config/passwall2 "$backup/passwall2"
uci commit passwall2
trap - EXIT
if ! /etc/init.d/passwall2 restart >/tmp/passwall-twitch-restart.log 2>&1; then
    cp -p "$backup/passwall2" /etc/config/passwall2
    /etc/init.d/passwall2 restart
    exit 1
fi
