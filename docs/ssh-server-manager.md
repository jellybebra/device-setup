[← К навигации](../README.md)

# SSH Server Manager

Интерактивный консольный менеджер SSH-подключений для настройки и управления Linux-серверами на базе **systemd** (Debian, Ubuntu, CentOS, Rocky и др.).

## Запуск менеджера

### macOS

**Удаленный запуск:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-mac.sh)
```

Вы можете настроить алиас (сокращение) для удобного запуска одной командой:
```bash
alias ssh-manager='bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-mac.sh)'
```

**Локальный запуск из корня репозитория:**
```bash
bash setup-ssh-mac.sh
```

### Windows (PowerShell)

**Удаленный запуск:**
```powershell
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-win.ps1 | iex
```

**Локальный запуск из корня репозитория:**
```powershell
.\setup-ssh-win.ps1
```

## Установка Fail2Ban

```bash
sudo apt install fail2ban
sudo systemctl enable fail2ban
```
