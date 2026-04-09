# Настройки устройства

## Быстрая настройка SSH

Чтобы использовать SSH ключи вместо пароля.

macOS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-mac.sh)
```
```bash
alias ssh-add-host='bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-mac.sh)'
```

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/setup-ssh-win.ps1 | iex
```

## Vencord

Windows:

```cmd
powershell -Command "$exe = \"$env:TEMP\VencordInstallerCli.exe\"; Invoke-WebRequest -Uri \"https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe\" -OutFile $exe; $p = Start-Process -PassThru -Wait -NoNewWindow -FilePath $exe -ArgumentList \"-install\", \"-branch\", \"auto\"; Remove-Item -Force $exe; if ($p.ExitCode -eq 0) { foreach ($name in @('Discord', 'DiscordPTB', 'DiscordCanary')) { $path = \"$env:LOCALAPPDATA\$name\Update.exe\"; if (Test-Path $path) { $exeName = if ($name -eq 'Discord') { 'Discord.exe' } else { \"$name.exe\" }; Start-Process $path -ArgumentList \"--processStart $exeName\"; break } } }"
```
