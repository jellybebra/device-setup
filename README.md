# SSH Server Manager

Интерактивный консольный менеджер SSH-подключений для настройки и управления Linux-серверами на базе **systemd** (Debian, Ubuntu, CentOS, Rocky и др.).

## Запуск менеджера

### macOS:

**Удаленный запуск:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-mac.sh)
```

Вы можете настроить алиас (сокращение) для удобного запуска одной командой:
```bash
alias ssh-manager='bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-mac.sh)'
```

**Локальный запуск:**
```bash
bash setup-ssh-mac.sh
```

### Windows (PowerShell):

**Удаленный запуск:**
```powershell
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-win.ps1 | iex
```

**Локальный запуск:**
```powershell
.\setup-ssh-win.ps1
```

---

### Установка Fail2Ban

   ```bash
   sudo apt install fail2ban
   sudo systemctl enable fail2ban
   ```

## Другие инструменты

Посмотреть что слушает на каком порту

```bash
ss -tl
```
```bash
netstat -tulpn
```

### Vencord

Windows:

```powershell
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/install-vencord.ps1 | iex
```

### Antigravity Proxy

macOS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/install-antigravity-v2rayn-mac.sh)
```

*(После запуска Finder откроет **Antigravity Proxy.app** — перетащите его в Dock)*

Windows:

```cmd
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/antigravity-fix.ps1 | iex
```

### ChatGPT Proxy

macOS (Electron-версия ChatGPT/Codex):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/chatgpt-proxy-mac.sh)
```

Установщик создаёт `~/Applications/ChatGPT Proxy.app` и показывает его в Finder — можно перетащить в Dock. Нужен ChatGPT в `/Applications/ChatGPT.app`; Python, Xcode и TUN не требуются.

1. Запустите v2rayN с HTTP/mixed-прокси на `127.0.0.1:10808`.
2. Дождитесь завершения задач и полностью закройте ChatGPT через **Cmd+Q**.
3. Откройте **ChatGPT Proxy.app**.

Launcher передаёт `--proxy-server`, `--proxy-bypass-list`, `--disable-quic` и переменные `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` (также в нижнем регистре). Localhost остаётся доступен напрямую. Используется существующий профиль; системные настройки не меняются. Уже открытое приложение launcher не завершает, а просит закрыть вручную.

Это не перехват всего трафика: программы, игнорирующие прокси, и UDP могут обходить его. Нативная, не Electron-версия ChatGPT не поддерживается.

Проверка приложения и доступности порта без запуска:

```bash
"$HOME/Applications/ChatGPT Proxy.app/Contents/MacOS/launcher" --check
```

Журнал: `~/Library/Logs/ChatGPT Proxy/launcher.log` (предыдущий запуск — `launcher.previous.log`). Для возврата к обычному запуску закройте ChatGPT и откройте его обычную иконку. Для удаления удалите `ChatGPT Proxy.app` и при желании папку журналов.

Windows:

```powershell
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/chatgpt-proxy.ps1 | iex
```

Все созданные данные находятся здесь:

```
%LOCALAPPDATA%\OpenAI\CodexProxyLauncher
```

### Fix компьютера

```cmd
sfc /scannow
DISM /Online /Cleanup-Image /RestoreHealth
```

### Fix Xbox games (от админа)

```cmd
cd %USERPROFILE%
icacls "AppData\Local\Packages" /grant "ALL APPLICATION PACKAGES":(F) /T /C
icacls "AppData\Local\Packages" /grant "ALL RESTRICTED APPLICATION PACKAGES":(F) /T /C
```

### MacOS, ПКМ по приложению, Remove Quarantine

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/install-remove-quarantine-mac.sh)
```

Удаление Quick Action:

```bash
rm -rf "$HOME/Library/Services/Remove Quarantine.workflow" &&
/System/Library/CoreServices/pbs -flush &&
killall Finder
```

### Codex rg fix

```powershell
winget install --id BurntSushi.ripgrep.MSVC -e
```
