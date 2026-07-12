# Быстрое действие Finder для удаления карантина (Remove Quarantine)

Вставь **весь блок целиком** в Terminal один раз. Он создаст Finder Quick Action с shell-скриптом и обновит меню Finder. Automator поддерживает Quick Actions в Finder и действие **Run Shell Script**. ([Apple Support][1])

```bash
SERVICE="$HOME/Library/Services/Remove Quarantine.workflow"
CONTENTS="$SERVICE/Contents"

rm -rf "$SERVICE"
mkdir -p "$CONTENTS"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>Remove Quarantine</string>
      </dict>
      <key>NSMessage</key>
      <string>runWorkflowAsService</string>
      <key>NSRequiredContext</key>
      <dict>
        <key>NSApplicationIdentifier</key>
        <string>com.apple.finder</string>
      </dict>
      <key>NSSendFileTypes</key>
      <array>
        <string>public.item</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

cat > "$CONTENTS/document.wflow" <<'WFLOW'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AMApplicationBuild</key>
  <string>523</string>
  <key>AMApplicationVersion</key>
  <string>2.10</string>
  <key>AMDocumentVersion</key>
  <string>2</string>

  <key>actions</key>
  <array>
    <dict>
      <key>action</key>
      <dict>
        <key>AMAccepts</key>
        <dict>
          <key>Container</key>
          <string>List</string>
          <key>Optional</key>
          <true/>
          <key>Types</key>
          <array>
            <string>com.apple.cocoa.path</string>
          </array>
        </dict>

        <key>AMActionVersion</key>
        <string>2.0.3</string>

        <key>AMApplication</key>
        <array>
          <string>Automator</string>
        </array>

        <key>AMParameterProperties</key>
        <dict>
          <key>COMMAND_STRING</key><dict/>
          <key>CheckedForUserDefaultShell</key><dict/>
          <key>inputMethod</key><dict/>
          <key>shell</key><dict/>
          <key>source</key><dict/>
        </dict>

        <key>AMProvides</key>
        <dict>
          <key>Container</key>
          <string>List</string>
          <key>Types</key>
          <array>
            <string>com.apple.cocoa.string</string>
          </array>
        </dict>

        <key>ActionBundlePath</key>
        <string>/System/Library/Automator/Run Shell Script.action</string>

        <key>ActionName</key>
        <string>Run Shell Script</string>

        <key>ActionParameters</key>
        <dict>
          <key>COMMAND_STRING</key>
          <string>status=0

for item in "$@"; do
  if ! /usr/bin/xattr -dr com.apple.quarantine "$item"; then
    status=1
  fi
done

if (( status == 0 )); then
  /usr/bin/osascript -e 'display notification "Quarantine attribute removed" with title "Remove Quarantine"'
else
  /usr/bin/osascript -e 'display dialog "Could not remove quarantine from one or more selected items." with title "Remove Quarantine" buttons {"OK"} default button "OK" with icon caution'
fi

exit $status</string>

          <key>CheckedForUserDefaultShell</key>
          <true/>

          <key>inputMethod</key>
          <integer>1</integer>

          <key>shell</key>
          <string>/bin/zsh</string>

          <key>source</key>
          <string></string>
        </dict>

        <key>BundleIdentifier</key>
        <string>com.apple.RunShellScript</string>

        <key>CFBundleVersion</key>
        <string>2.0.3</string>

        <key>CanShowSelectedItemsWhenRun</key>
        <false/>

        <key>CanShowWhenRun</key>
        <true/>

        <key>Category</key>
        <array>
          <string>AMCategoryUtilities</string>
        </array>

        <key>Class Name</key>
        <string>RunShellScriptAction</string>

        <key>InputUUID</key>
        <string>42D101D0-3A59-4C36-86CB-A5233D880001</string>

        <key>OutputUUID</key>
        <string>42D101D0-3A59-4C36-86CB-A5233D880002</string>

        <key>UUID</key>
        <string>42D101D0-3A59-4C36-86CB-A5233D880003</string>

        <key>UnlocalizedApplications</key>
        <array>
          <string>Automator</string>
        </array>

        <key>arguments</key>
        <dict>
          <key>0</key>
          <dict>
            <key>default value</key>
            <integer>0</integer>
            <key>name</key>
            <string>inputMethod</string>
            <key>required</key>
            <string>0</string>
            <key>type</key>
            <string>0</string>
            <key>uuid</key>
            <string>0</string>
          </dict>
        </dict>

        <key>isViewVisible</key>
        <integer>1</integer>

        <key>location</key>
        <string>449.500000:620.000000</string>

        <key>nibPath</key>
        <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
      </dict>

      <key>isViewVisible</key>
      <integer>1</integer>
    </dict>
  </array>

  <key>connectors</key>
  <dict/>

  <key>workflowMetaData</key>
  <dict>
    <key>serviceApplicationBundleID</key>
    <string>com.apple.finder</string>

    <key>serviceApplicationPath</key>
    <string>/System/Library/CoreServices/Finder.app</string>

    <key>serviceInputTypeIdentifier</key>
    <string>com.apple.Automator.fileSystemObject</string>

    <key>serviceOutputTypeIdentifier</key>
    <string>com.apple.Automator.nothing</string>

    <key>serviceProcessesInput</key>
    <integer>0</integer>

    <key>workflowTypeIdentifier</key>
    <string>com.apple.Automator.servicesMenu</string>
  </dict>
</dict>
</plist>
WFLOW

plutil -lint "$CONTENTS/Info.plist" "$CONTENTS/document.wflow" &&
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

killall Finder 2>/dev/null || true

echo "Installed: Remove Quarantine"
```

## Использование

```text
Finder → right-click по .app → Quick Actions → Remove Quarantine
```

Можно выделить сразу несколько приложений.

## Если пункт скрыт

```text
System Settings → Privacy & Security → Extensions → Finder
```

## Для удаления Quick Action

```bash
rm -rf "$HOME/Library/Services/Remove Quarantine.workflow" &&
/System/Library/CoreServices/pbs -flush &&
killall Finder
```

[1]: https://support.apple.com/en-ke/guide/automator/autbbd4cc11c/2.10/mac/15.0?utm_source=chatgpt.com "Use a shell script action in an Automator workflow on Mac"
