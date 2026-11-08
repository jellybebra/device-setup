# Vencord

## Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/jellybebra/device-setup/main/install-vencord.ps1 | iex
```

## Запуск с восстановлением Vencord через панель задач

Встроенное автообновление Vencord работает только пока мод загружается в Discord.
Обновление самого Discord может заменить загрузчик и убрать раздел Vencord из настроек.

Для уже установленных Discord Stable и Vencord с закреплённым ярлыком Discord
запусти из локальной копии репозитория (Windows PowerShell 5.1, текущий пользователь):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-vencord-launcher.ps1 -Mode Install
```

Установка заменяет цель существующего ярлыка Discord на панели задач, сохраняя значок,
и удаляет прежнюю периодическую задачу. При нажатии запускается GUI-загрузчик без
консоли; он проверяет Vencord, при необходимости восстанавливает его и открывает Discord.
Первые 60 секунд запуска он также обрабатывает замену файлов при обновлении Discord,
после чего завершается. Постоянного процесса, проверок по таймеру и задачи при входе нет.
Если Discord уже открыт, обычное нажатие на его группу в панели задач переключает окно,
как и прежде; ярлык выполняется при новом запуске.

Когда Vencord подключён, проверка ничего не скачивает и не перезапускает. При настройке скрипт скачивает
[официальный установщик](https://github.com/Vencord/Installer) и проверяет SHA256 по данным
релиза GitHub. Если подключение пропало, установщик подключает уже имеющиеся файлы Vencord
без необходимости скачивать сборку: восстановление работает и без сети.
Обновлением самой сборки после запуска занимается встроенное автообновление Vencord.
Если Discord был открыт, установщик закроет его, а скрипт откроет снова — это прервёт
текущий звонок. Обновления, случившиеся уже после завершения проверки запуска,
обрабатываются при следующем запуске через ярлык.

Рабочая копия скрипта и журналы находятся в `%USERPROFILE%\.device-setup\VencordRepair`,
поэтому удаление Git worktree не нарушает работу ярлыка. Настройки Vencord сохраняются.
Для установки новой версии скрипта повтори `-Mode Install`.
Оригинальный ярлык сохранён там же как `Discord.original.lnk`.

Проверка:

```powershell
.\setup-vencord-launcher.ps1 -Mode Check
Get-Content "$env:USERPROFILE\.device-setup\VencordRepair\repair.log" -Tail 20
```

Для возврата обычного запуска восстанови `Discord.original.lnk` на место
`%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Discord.lnk`.

## Файлы и проверки

- [`install-vencord.ps1`](../install-vencord.ps1) — обычная установка Vencord.
- [`setup-vencord-launcher.ps1`](../setup-vencord-launcher.ps1) — настройка ярлыка и восстановление при запуске.
- [`vencord-launcher.cs`](../vencord-launcher.cs) — исходник запуска без консоли; EXE компилируется локально при настройке.

Проверки используют временные фикстуры, не меняют настоящий Discord и не создают задачи:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\vencord-repair.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\vencord-launcher.Tests.ps1
```
