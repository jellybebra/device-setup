[← К навигации](../README.md)

# Исправление Xbox games

Выполните команды в командной строке от имени администратора:

```cmd
cd %USERPROFILE%
icacls "AppData\Local\Packages" /grant "ALL APPLICATION PACKAGES":(F) /T /C
icacls "AppData\Local\Packages" /grant "ALL RESTRICTED APPLICATION PACKAGES":(F) /T /C
```
