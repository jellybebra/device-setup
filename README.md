# Менеджер SSH серверов (SSH Server Manager)

Интерактивный менеджер SSH-подключений для терминала с удобным выбором серверов стрелочками, возможностью добавления, редактирования и удаления серверов из вашего конфигурационного файла `~/.ssh/config`.

## Запуск менеджера

### macOS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-mac.sh)
```

Вы можете настроить алиас (сокращение) для удобного запуска одной командой:
```bash
alias ssh-manager='bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-mac.sh)'
```

### Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-win.ps1 | iex
```

---

## Другие инструменты

### Vencord

Windows:

```cmd
powershell -Command "$exe = \"$env:TEMP\VencordInstallerCli.exe\"; Invoke-WebRequest -Uri \"https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe\" -OutFile $exe; $p = Start-Process -PassThru -Wait -NoNewWindow -FilePath $exe -ArgumentList \"-install\", \"-branch\", \"auto\"; Remove-Item -Force $exe; if ($p.ExitCode -eq 0) { foreach ($name in @('Discord', 'DiscordPTB', 'DiscordCanary')) { $path = \"$env:LOCALAPPDATA\$name\Update.exe\"; if (Test-Path $path) { $exeName = if ($name -eq 'Discord') { 'Discord.exe' } else { \"$name.exe\" }; Start-Process $path -ArgumentList \"--processStart $exeName\"; break } } }"
```