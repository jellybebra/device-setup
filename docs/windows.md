[← К навигации](../README.md)

# Настройка и восстановление Windows

## Восстановление системных файлов

```cmd
sfc /scannow
DISM /Online /Cleanup-Image /RestoreHealth
```

## Исправление Xbox games (от администратора)

```cmd
cd %USERPROFILE%
icacls "AppData\Local\Packages" /grant "ALL APPLICATION PACKAGES":(F) /T /C
icacls "AppData\Local\Packages" /grant "ALL RESTRICTED APPLICATION PACKAGES":(F) /T /C
```

## Установка ripgrep для Codex

```powershell
winget install --id BurntSushi.ripgrep.MSVC -e
```
