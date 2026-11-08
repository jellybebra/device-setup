#!/bin/sh
set -eu
# This key and feed are documented by the upstream PassWall2 project.
curl --fail --location --max-time 60 --proxy http://127.0.0.1:18080 \
  https://sourceforge.net/projects/openwrt-passwall-build/files/apk.pub \
  -o /tmp/passwall.pub
grep -q 'BEGIN PUBLIC KEY' /tmp/passwall.pub
cp /tmp/passwall.pub /etc/apk/keys/passwall.pub
cat > /etc/apk/repositories.d/passwall.list <<'EOF'
https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-25.12/aarch64_cortex-a53/passwall_packages/packages.adb
https://sourceforge.net/projects/openwrt-passwall-build/files/releases/packages-25.12/aarch64_cortex-a53/passwall2/packages.adb
EOF
apk update
apk add \
  luci-app-passwall2 xray-core chinadns-ng \
  kmod-nft-socket kmod-nft-tproxy kmod-nft-nat kmod-nft-queue \
  ca-bundle bind-dig
