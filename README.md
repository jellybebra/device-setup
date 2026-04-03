# ssh-setup

Быстро настроить SSH конфиг для использования SSH ключей вместо пароля.

macOS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/ssh-setup/main/setup-ssh-mac.sh)
```
```bash
alias ssh-add-host='bash <(curl -fsSL https://raw.githubusercontent.com/jellybebra/ssh-setup/main/setup-ssh-mac.sh)'
```

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/jellybebra/ssh-setup/main/setup-ssh-win.ps1 | iex
```
