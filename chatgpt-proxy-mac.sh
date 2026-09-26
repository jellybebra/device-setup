#!/bin/bash
# Creates a launcher for the Electron-based ChatGPT/Codex desktop app.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Этот установщик предназначен для macOS.' >&2
  exit 1
fi
SOURCE_APP='/Applications/ChatGPT.app'
if [[ ! -x "$SOURCE_APP/Contents/MacOS/ChatGPT" ]]; then
  echo 'Не найден /Applications/ChatGPT.app.' >&2
  exit 1
fi
if [[ ! -d "$SOURCE_APP/Contents/Frameworks/Codex Framework.framework" && ! -d "$SOURCE_APP/Contents/Frameworks/Electron Framework.framework" ]]; then
  echo 'Нужна Electron-версия ChatGPT/Codex. Нативная версия ChatGPT этим launcher не поддерживается.' >&2
  exit 1
fi
INSTALL_DIR="${CHATGPT_PROXY_INSTALL_DIR:-$HOME/Applications}"
APP_DIR="$INSTALL_DIR/ChatGPT Proxy.app"
BUNDLE_ID='io.github.jellybebra.chatgpt-proxy'
mkdir -p "$INSTALL_DIR"
if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)
  if [[ -L "$APP_DIR" || "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Отказ от перезаписи другого приложения: $APP_DIR" >&2
    exit 1
  fi
fi
STAGE=$(mktemp -d "$INSTALL_DIR/.chatgpt-proxy.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
CONTENTS="$STAGE/ChatGPT Proxy.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cat > "$CONTENTS/MacOS/launcher" <<'LAUNCHER_EOF'
#!/bin/bash
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
APP='/Applications/ChatGPT.app'
PROXY='http://127.0.0.1:10808'
EXE="$APP/Contents/MacOS/ChatGPT"
CHECK_ONLY=false
[[ "${1:-}" == '--check' ]] && CHECK_ONLY=true
alert() {
  if $CHECK_ONLY; then printf '%s\n' "$1" >&2; else
    /usr/bin/osascript - "$1" <<'APPLESCRIPT'
on run argv
  display dialog (item 1 of argv) with title "ChatGPT Proxy" buttons {"OK"} default button "OK" with icon caution
end run
APPLESCRIPT
  fi
}
if [[ ! -x "$EXE" ]]; then
  alert 'Не найден /Applications/ChatGPT.app. Установите ChatGPT в Applications.'
  exit 1
fi
if ! /usr/bin/nc -z -G 2 127.0.0.1 10808 >/dev/null 2>&1; then
  alert 'Прокси 127.0.0.1:10808 недоступен. Запустите v2rayN и выберите сервер.'
  exit 2
fi
export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" ALL_PROXY="$PROXY"
export http_proxy="$PROXY" https_proxy="$PROXY" all_proxy="$PROXY"
export NO_PROXY='localhost,127.0.0.1,::1' no_proxy='localhost,127.0.0.1,::1'
ARGS=("--proxy-server=$PROXY" '--proxy-bypass-list=localhost;127.0.0.1;[::1]' '--disable-quic')
if $CHECK_ONLY; then
  printf 'Application: %s\nProxy: %s\n' "$EXE" "$PROXY"
  printf 'Argument: %s\n' "${ARGS[@]}"
  printf 'Local proxy is listening. No application was started or stopped.\n'
  exit 0
fi
# A running singleton would ignore the new environment and launch arguments.
if /bin/ps -axo comm= | /usr/bin/awk -v exe="$EXE" '$0 == exe { found=1 } END { exit !found }'; then
  alert 'ChatGPT уже запущен. Дождитесь завершения текущих задач, закройте его через ⌘Q и снова откройте ChatGPT Proxy. Для применения прокси нужен полный новый запуск.'
  exit 0
fi
LOG_DIR="$HOME/Library/Logs/ChatGPT Proxy"
umask 077
mkdir -p "$LOG_DIR"
# Keep only the previous launch log; do not enable network/token logging.
[[ ! -f "$LOG_DIR/launcher.log" ]] || mv -f "$LOG_DIR/launcher.log" "$LOG_DIR/launcher.previous.log"
unset ELECTRON_RUN_AS_NODE || true
/usr/bin/nohup "$EXE" "${ARGS[@]}" </dev/null >"$LOG_DIR/launcher.log" 2>&1 &
APP_PID=$!
sleep 3
if ! kill -0 "$APP_PID" 2>/dev/null; then
  alert 'ChatGPT завершился сразу после запуска. Журнал: ~/Library/Logs/ChatGPT Proxy/launcher.log'
  exit 3
fi
LAUNCHER_EOF
cat > "$CONTENTS/Info.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>ChatGPT Proxy</string>
	<key>CFBundleExecutable</key>
	<string>launcher</string>
	<key>CFBundleIconFile</key>
	<string>launcher.icns</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.jellybebra.chatgpt-proxy</string>
	<key>CFBundleName</key>
	<string>ChatGPT Proxy</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST_EOF
chmod 755 "$CONTENTS/MacOS/launcher"
for ICON in icon-chatgpt.icns electron.icns app.icns; do
  if [[ -f "$SOURCE_APP/Contents/Resources/$ICON" ]]; then
    cp "$SOURCE_APP/Contents/Resources/$ICON" "$CONTENTS/Resources/launcher.icns"
    break
  fi
done
/bin/bash -n "$CONTENTS/MacOS/launcher"
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null
# Keep the previous installation until the replacement is in place.
if [[ -d "$APP_DIR" ]]; then
  mv "$APP_DIR" "$STAGE/previous.app"
fi
if ! mv "$STAGE/ChatGPT Proxy.app" "$APP_DIR"; then
  [[ ! -d "$STAGE/previous.app" ]] || mv "$STAGE/previous.app" "$APP_DIR"
  exit 1
fi
printf 'Готово: %s\n' "$APP_DIR"
echo 'Запустите v2rayN. Закройте ChatGPT через Cmd+Q, затем откройте ChatGPT Proxy.app.'
if [[ "${CHATGPT_PROXY_REVEAL:-1}" != 0 ]]; then
  /usr/bin/open -R "$APP_DIR"
fi
