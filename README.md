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

```cmd
powershell -Command "$exe = \"$env:TEMP\VencordInstallerCli.exe\"; Invoke-WebRequest -Uri \"https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe\" -OutFile $exe; $p = Start-Process -PassThru -Wait -NoNewWindow -FilePath $exe -ArgumentList \"-install\", \"-branch\", \"auto\"; Remove-Item -Force $exe; if ($p.ExitCode -eq 0) { foreach ($name in @('Discord', 'DiscordPTB', 'DiscordCanary')) { $path = \"$env:LOCALAPPDATA\$name\Update.exe\"; if (Test-Path $path) { $exeName = if ($name -eq 'Discord') { 'Discord.exe' } else { \"$name.exe\" }; Start-Process $path -ArgumentList \"--processStart $exeName\"; break } } }"
```