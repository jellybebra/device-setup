[← К навигации](../README.md)

# ChatGPT Proxy

## macOS (Electron-версия ChatGPT/Codex)

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

## Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/chatgpt-proxy.ps1 | iex
```

Все созданные данные находятся здесь:

```
%LOCALAPPDATA%\OpenAI\CodexProxyLauncher
```
