#!/bin/bash
set -euo pipefail

APP_DIR="$HOME/Applications/Antigravity Proxy.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SUPPORT_DIR="$HOME/Library/Application Support/Antigravity Proxy"
LAUNCHER="$SUPPORT_DIR/launcher.sh"

mkdir -p "$MACOS" "$RESOURCES" "$SUPPORT_DIR"

cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
set -euo pipefail

PROXY_HOST="${ANTIGRAVITY_PROXY_HOST:-127.0.0.1}"
SOCKS_PORT="${ANTIGRAVITY_SOCKS_PORT:-10808}"
HTTP_PORT="${ANTIGRAVITY_HTTP_PORT:-10809}"
LOG_DIR="$HOME/Library/Logs/antigravity-v2rayn"
NO_PROXY_VALUE="${NO_PROXY:-localhost,127.0.0.1,::1,*.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
BYPASS_LIST="<local>;localhost;127.0.0.1;::1;*.local;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*"

log() {
  printf '[antigravity-v2rayn] %s\n' "$*"
}

notify() {
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

find_app() {
  if [[ -n "${ANTIGRAVITY_APP_PATH:-}" ]]; then
    [[ -d "$ANTIGRAVITY_APP_PATH" ]] || return 1
    printf '%s\n' "$ANTIGRAVITY_APP_PATH"
    return
  fi

  local candidate
  for candidate in \
    "/Applications/Antigravity.app" \
    "/Applications/Antigravity IDE.app" \
    "$HOME/Applications/Antigravity.app" \
    "$HOME/Applications/Antigravity IDE.app"
  do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

port_open() {
  /usr/bin/nc -z -w 1 "$PROXY_HOST" "$1" >/dev/null 2>&1
}

test_socks() {
  /usr/bin/curl -fsS --max-time 10 \
    --proxy "socks5h://${PROXY_HOST}:${SOCKS_PORT}" \
    https://www.gstatic.com/generate_204 \
    -o /dev/null
}

test_http_port() {
  /usr/bin/curl -fsS --max-time 10 \
    --proxy "http://${PROXY_HOST}:$1" \
    https://www.gstatic.com/generate_204 \
    -o /dev/null
}

detect_http_proxy() {
  local candidate
  for candidate in "$HTTP_PORT" "$SOCKS_PORT"; do
    if port_open "$candidate" && test_http_port "$candidate"; then
      printf 'http://%s:%s\n' "$PROXY_HOST" "$candidate"
      return
    fi
  done
  return 1
}

stop_existing_app() {
  local bundle_id="$1"
  local executable="$2"

  if [[ -n "$bundle_id" ]]; then
    /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  fi

  local i
  for i in {1..20}; do
    if ! /usr/bin/pgrep -f "$executable" >/dev/null 2>&1; then
      return
    fi
    /bin/sleep 0.25
  done

  /usr/bin/pkill -f "$executable" >/dev/null 2>&1 || true
  /bin/sleep 1
}

main() {
  local app plist executable_name executable bundle_id http_proxy chromium_proxy log_file pid

  if ! port_open "$SOCKS_PORT"; then
    notify "Antigravity Proxy" "v2rayN SOCKS5 port ${PROXY_HOST}:${SOCKS_PORT} is closed."
    exit 1
  fi

  if ! test_socks; then
    notify "Antigravity Proxy" "SOCKS5 proxy test failed."
    exit 1
  fi

  if ! app="$(find_app)"; then
    notify "Antigravity Proxy" "Antigravity.app was not found."
    exit 1
  fi

  plist="$app/Contents/Info.plist"
  executable_name="$(plist_value "$plist" "CFBundleExecutable")"
  bundle_id="$(plist_value "$plist" "CFBundleIdentifier")"
  executable="$app/Contents/MacOS/$executable_name"

  if [[ -z "$executable_name" || ! -x "$executable" ]]; then
    notify "Antigravity Proxy" "Antigravity executable was not found."
    exit 1
  fi

  http_proxy=""
  if http_proxy="$(detect_http_proxy)"; then
    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$http_proxy"
    export http_proxy="$http_proxy"
    export https_proxy="$http_proxy"
    export GRPC_PROXY="$http_proxy"
    export GRPC_PROXY_EXP="$http_proxy"
  fi

  export ALL_PROXY="socks5h://${PROXY_HOST}:${SOCKS_PORT}"
  export all_proxy="$ALL_PROXY"
  export NO_PROXY="$NO_PROXY_VALUE"
  export no_proxy="$NO_PROXY_VALUE"

  chromium_proxy="socks5://${PROXY_HOST}:${SOCKS_PORT}"

  stop_existing_app "$bundle_id" "$executable"

  mkdir -p "$LOG_DIR"
  log_file="$LOG_DIR/antigravity-$(date +%Y%m%d-%H%M%S).log"

  nohup "$executable" \
    "--proxy-server=$chromium_proxy" \
    "--proxy-bypass-list=$BYPASS_LIST" \
    "--disable-quic" \
    >>"$log_file" 2>&1 &

  pid=$!
  /bin/sleep 2

  if ! /bin/kill -0 "$pid" >/dev/null 2>&1; then
    notify "Antigravity Proxy" "Antigravity exited. Check the log folder."
    /usr/bin/open "$LOG_DIR" >/dev/null 2>&1 || true
    exit 1
  fi
}

main "$@"
LAUNCHER_EOF

chmod +x "$LAUNCHER"

cat > "$MACOS/Antigravity Proxy" <<APP_EOF
#!/bin/bash
exec "$LAUNCHER"
APP_EOF
chmod +x "$MACOS/Antigravity Proxy"

ICON_NAME=""
ORIGINAL_APP=""
for CANDIDATE in \
  "/Applications/Antigravity.app" \
  "/Applications/Antigravity IDE.app" \
  "$HOME/Applications/Antigravity.app" \
  "$HOME/Applications/Antigravity IDE.app"
do
  if [[ -d "$CANDIDATE" ]]; then
    ORIGINAL_APP="$CANDIDATE"
    break
  fi
done

if [[ -n "$ORIGINAL_APP" ]]; then
  ORIGINAL_ICON="$(find "$ORIGINAL_APP/Contents/Resources" -maxdepth 1 -name '*.icns' -print -quit 2>/dev/null || true)"
  if [[ -n "$ORIGINAL_ICON" ]]; then
    cp "$ORIGINAL_ICON" "$RESOURCES/Antigravity.icns"
    ICON_NAME="<key>CFBundleIconFile</key><string>Antigravity.icns</string>"
  fi
fi

cat > "$CONTENTS/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>English</string>
  <key>CFBundleDisplayName</key>
  <string>Antigravity Proxy</string>
  <key>CFBundleExecutable</key>
  <string>Antigravity Proxy</string>
  <key>CFBundleIdentifier</key>
  <string>local.antigravity.proxy</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Antigravity Proxy</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>LSUIElement</key>
  <true/>
  $ICON_NAME
</dict>
</plist>
PLIST_EOF

/usr/bin/xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
/usr/bin/touch "$APP_DIR"

/usr/bin/open -R "$APP_DIR"

echo
echo "Installed:"
echo "  $APP_DIR"
echo
echo "Drag “Antigravity Proxy” to the Dock and launch it instead of the original app."
