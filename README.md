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

### Antigravity Proxy Fix

Windows:

```cmd
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/antigravity-fix.ps1 | iex
```

### ChatGPT Proxy

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
