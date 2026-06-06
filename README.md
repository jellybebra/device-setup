# Менеджер SSH серверов (SSH Server Manager)

Интерактивный менеджер SSH-подключений для терминала с удобным выбором серверов стрелочками, возможностью добавления, редактирования и удаления серверов из вашего конфигурационного файла `~/.ssh/config`.

Инструмент предназначен для настройки и управления удаленными Linux-серверами на базе **systemd** (Debian, Ubuntu, CentOS, Rocky и др.).

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

## Другие инструменты

### Vencord

Windows:

```cmd
powershell -Command "$exe = \"$env:TEMP\VencordInstallerCli.exe\"; Invoke-WebRequest -Uri \"https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe\" -OutFile $exe; $p = Start-Process -PassThru -Wait -NoNewWindow -FilePath $exe -ArgumentList \"-install\", \"-branch\", \"auto\"; Remove-Item -Force $exe; if ($p.ExitCode -eq 0) { foreach ($name in @('Discord', 'DiscordPTB', 'DiscordCanary')) { $path = \"$env:LOCALAPPDATA\$name\Update.exe\"; if (Test-Path $path) { $exeName = if ($name -eq 'Discord') { 'Discord.exe' } else { \"$name.exe\" }; Start-Process $path -ArgumentList \"--processStart $exeName\"; break } } }"
```

# Настройка нового сервера

## 1. Настройка SSH и пользователей

### 1.1. Настройка сервера

1. Обновите пакеты:

   ```bash
   sudo apt update
   sudo apt upgrade
   ```

2. Поменяй пароль на сложный
### 1.2. Настройка SSH-сервера

1. Перезагрузите сервер:

   ```bash
   sudo reboot
   ```

## 2. Настройка безопасности

### 2.2. Установка Fail2Ban
1. Установите и включите защиту от bruteforce-атак:

   ```bash
   sudo apt install fail2ban
   sudo systemctl enable fail2ban
   ```

Посмотреть что слушает на каком порту

```bash
ss -tl
```
```bash
netstat -tulpn
```

```bash
apt update && apt install unattended-upgrades
dpkg-reconfigure --priority=low unattended-upgrades
```