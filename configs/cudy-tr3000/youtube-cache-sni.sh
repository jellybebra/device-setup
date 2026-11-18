#!/bin/sh
set -eu

# Load the matching fw4 include after PassWall regenerates its Xray rules.
[ "$(uci -q get passwall2.split.protocol)" = "_shunt" ]
group=$(uci get passwall2.split.shunt_group)
uci set passwall2.YouTubeCacheSNI=shunt_rules
uci set passwall2.YouTubeCacheSNI.remarks='YouTube local cache TLS'
uci set passwall2.YouTubeCacheSNI.group="$group"
uci set passwall2.YouTubeCacheSNI.inbound='tproxy'
uci set passwall2.YouTubeCacheSNI.network='tcp'
uci set passwall2.YouTubeCacheSNI.port='443'
uci set passwall2.YouTubeCacheSNI.domain_list='regexp:^rr[^.]*---sn-gvnuxaxjvh-3gg6\.googlevideo\.com$
regexp:^rr[^.]*---sn-gvnuxaxjvh-3ggl\.googlevideo\.com$
regexp:^rr[^.]*---sn-gvnuxaxjvh-3ggz\.googlevideo\.com$
regexp:^rr[^.]*---sn-hxb54vo-3gg6\.googlevideo\.com$'
uci set passwall2.split.YouTubeCacheSNI='_blackhole'
uci commit passwall2
