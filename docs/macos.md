# Remove Quarantine для macOS

Quick Action для удаления карантина через контекстное меню приложения в Finder.

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/device-setup/main/install-remove-quarantine-mac.sh)
```

## Удаление Quick Action

```bash
rm -rf "$HOME/Library/Services/Remove Quarantine.workflow" &&
/System/Library/CoreServices/pbs -flush &&
killall Finder
```
