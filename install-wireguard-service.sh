#!/usr/bin/env bash
set -euo pipefail
[[ $EUID == 0 ]]
SOURCE=${1:-/opt/warp-wireguard-test/server.conf}
ROOT=/etc/device-setup/warp-wireguard
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
[[ -s "$SOURCE" && -s "$HERE/wireguard-service.sh" ]]
install -d -m 700 "$ROOT"
if [[ ! -f "$ROOT/server.conf" ]]; then
  install -m 600 "$SOURCE" "$ROOT/server.conf"
fi
touch "$ROOT/managed"
install -m 700 "$HERE/wireguard-service.sh" /usr/local/sbin/device-setup-wireguard
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-device-setup-wireguard.conf
cat > /etc/systemd/system/device-setup-wireguard.service <<'UNIT'
[Unit]
Description=DeviceSetup WireGuard VPN
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/device-setup-wireguard up
ExecReload=/usr/local/sbin/device-setup-wireguard up
TimeoutStartSec=60
Restart=on-failure
RestartSec=10
# Stopping this management unit deliberately does not tear down active clients.

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now device-setup-wireguard.service
systemctl is-enabled device-setup-wireguard.service
systemctl is-active device-setup-wireguard.service
