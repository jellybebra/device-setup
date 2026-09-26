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

### Проброс порта через UPnP в Windows

Пример для Minecraft Java: внешний TCP-порт `25565` направляется на порт `25565` этого компьютера. Нужны включённый UPnP на роутере и доступный из интернета внешний IP. UPnP на домашнем роутере сам по себе не обходит NAT провайдера (CGNAT).

**Создать проброс одной командой в обычном PowerShell:**

```powershell
(New-Object -ComObject HNetCfg.NATUPnP).StaticPortMappingCollection.Add(25565, 'TCP', 25565, (Get-NetIPConfiguration -InterfaceAlias 'Ethernet').IPv4Address.IPAddress, $true, 'Minecraft')
```

Команда автоматически берёт текущий IPv4-адрес интерфейса `Ethernet`. Если подключение идёт через другой интерфейс, замените `Ethernet` его именем из `Get-NetIPConfiguration`. Первое число — внешний порт роутера, второе — порт приложения на компьютере; `'Minecraft'` — описание правила.

В результате команда покажет `ExternalIPAddress` и `ExternalPort`: игроки подключаются к `ExternalIPAddress:ExternalPort`. Сам Minecraft должен быть запущен, слушать TCP-порт `25565`, а брандмауэр Windows — разрешать входящие подключения к нему. Команда создаёт правило на роутере, но не меняет брандмауэр Windows.

**Посмотреть существующие пробросы:**

```powershell
(New-Object -ComObject HNetCfg.NATUPnP).StaticPortMappingCollection | Format-Table ExternalIPAddress, ExternalPort, Protocol, InternalClient, InternalPort, Enabled, Description
```

**Удалить проброс:**

```powershell
(New-Object -ComObject HNetCfg.NATUPnP).StaticPortMappingCollection.Remove(25565, 'TCP')
```

После создания правила PowerShell можно закрыть: трафик пересылает сам роутер, дополнительные программы и фоновые скрипты не нужны. Закрытие Minecraft не удаляет правило; сервер станет недоступен, пока приложение снова не начнёт слушать порт.

**Срок действия и изменения адресов:**

- На проверенном ZyXEL Keenetic 4G III правило создано с `LeaseDuration = 0`: в используемом им UPnP IGD v1 это означает отсутствие срока истечения. Продление по таймеру не требуется. Другие роутеры и версии UPnP могут ограничивать срок.
- После перезагрузки роутера или перезапуска UPnP правило может исчезнуть. Проверьте список пробросов и при необходимости создайте его заново.
- При смене локального IP правило остаётся направленным на старый адрес. Лучше закрепить адрес компьютера в DHCP-настройках роутера. Если адрес уже сменился, удалите своё старое правило и создайте новое.
- При смене внешнего IP игрокам понадобится новый адрес подключения.
- Повторное создание того же правила для того же компьютера обновляет его. Если внешний порт уже направлен на другой компьютер, возможен конфликт; не удаляйте чужое правило.

**Если используется v2rayN с TUN:** в проверенной конфигурации прямой проброс заработал после отключения **«Строгая маршрутизация / Strict route»** в настройках TUN и его выключения-включения. Сам TUN оставался включённым; исключения по IP игроков не понадобились. Это результат проверки конкретной конфигурации, а не обязательная настройка для всех VPN-клиентов.

Документация: [UPnP API Windows — Add](https://learn.microsoft.com/en-us/windows/win32/api/natupnp/nf-natupnp-istaticportmappingcollection-add), [UPnP WANIPConnection v1 — срок действия и обновление правил](https://upnp.org/specs/gw/UPnP-gw-WANIPConnection-v1-Service.pdf).

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
