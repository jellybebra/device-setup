#!/bin/sh
set -eu

# PassWall2's LAN DNS instance inherits this file on every start. The
# selector has the regional-cache exclusions and resolves the other caches.
config=/etc/dnsmasq.conf
candidate=$(mktemp /etc/dnsmasq.conf.youtube.XXXXXX)
trap 'rm -f "$candidate"' EXIT
cp -p "$config" "$candidate"
for rule in 'server=/googlevideo.com/127.0.0.1#15355' \
            'nftset=/googlevideo.com/4#inet#fw4#youtube_video_v4'; do
    grep -Fxq "$rule" "$candidate" || printf '\n%s\n' "$rule" >> "$candidate"
done
if ! cmp -s "$candidate" "$config"; then
    dnsmasq --test --conf-file="$candidate"
    mv "$candidate" "$config"
fi
