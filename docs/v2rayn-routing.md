# v2rayN 7.24.9

## Профили компьютеров

| Профиль | Google / YouTube | Discord, включая голос | Правила Routing Setting | Шаблон Xray |
| --- | --- | --- | --- | --- |
| Windows | Напрямую | Напрямую | [windows/routes.json](../configs/v2rayn/windows/routes.json) | [windows/xray-template.json](../configs/v2rayn/windows/xray-template.json) |
| macOS | Через прокси | Через прокси | [macos/routes.json](../configs/v2rayn/macos/routes.json) | [macos/xray-template.json](../configs/v2rayn/macos/xray-template.json) |

## Загрузки Steam

В обоих профилях загрузки с `steamcontent.com` (включая поддомены) и CDN `steampipe.akamaized.net`, `steampipe-kr.akamaized.net`, `steampipe-partner.akamaized.net` идут напрямую. Правило стоит **перед** общим `geosite:steam → proxy`; магазин, сообщество и остальные домены Steam продолжают использовать прокси. Список CDN можно сверить с [категорией Steam в domain-list-community](https://github.com/v2fly/domain-list-community/blob/master/data/steam).

После применения правил нажми **Reload** в v2rayN, затем приостанови и возобнови загрузку Steam, чтобы соединения открылись с новым маршрутом. При TUN или системном прокси трафик может по-прежнему проходить через локальный v2rayN, но для этих CDN используется выход `direct` без удалённого прокси-сервера.

## Обновление уже настроенного v2rayN на Windows

Запусти v2rayN и выполни из корня репозитория (нужен Python 3, дополнительные библиотеки не нужны):

```powershell
python .\update-v2rayn.py
```

Скрипт находит папку запущенного v2rayN, скачивает Windows-профиль из актуального `main` на GitHub и обновляет **оба полных шаблона Xray** и **активный профиль `device-setup-windows`**. Оба файла скачиваются из одного коммита. Перед записью он проверяет шаблон установленным Xray с текущим сервером и Geo-файлами, а затем сохраняет согласованную копию SQLite и `guiNConfig.json` в `%LOCALAPPDATA%\v2rayN-backups\routing-…`.

Серверы, подписки, DNS, настройки TUN и другие профили сохраняются. Список правил `device-setup-windows` заменяется целиком. Если всё уже совпадает, повторный запуск ничего не записывает. Скрипт не нажимает Reload и не переключает TUN — после обновления нажми **Reload** сам. Если сайт всё ещё не открывается или перенаправляет на региональную ошибку, **полностью перезапусти браузер после Reload**: перезапуск службы v2rayN не очищает кэш браузера. При необходимости переподключи TUN.

Дополнительные варианты:

```powershell
# Сравнить и проверить Xray, не меняя настройки
python .\update-v2rayn.py --check

# Применить файлы текущего checkout, включая ещё не опубликованные изменения
python .\update-v2rayn.py --local

# Явно указать установку, если v2rayN закрыт или запущено несколько экземпляров
python .\update-v2rayn.py --app-dir 'C:\Tools\v2rayN'
```

Это обновление существующей настройки, проверенное с v2rayN 7.24.9. Папка установки должна содержать `guiConfigs/guiNDB.db`, `guiConfigs/guiNConfig.json`, `binConfigs/config.json` и `bin/xray/xray.exe`. Если используется другая папка данных или активен другой профиль, скрипт остановится с объяснением; старые установки он не выбирает наугад. Первичная настройка описана ниже.

Для отката закрой v2rayN и восстанови `guiNDB.db` из нужной резервной копии в его `guiConfigs`. Копия содержит также серверы и подписки на момент обновления. `guiNConfig.json` скрипт не меняет; его копия сохраняется для справки.

## Приоритет sing-box в Windows

На этом компьютере для `sing-box.exe` установлен приоритет **AboveNormal / Выше обычного**. Настройка применена 9 октября 2026 года к работающему процессу и сохранена для следующих запусков, включая перезапуск Windows. TUN и игровое соединение при применении не перезапускались.

### Причина: скачки пинга в Battlefield 6

Проверено с v2rayN 7.24.9, sing-box 1.13.12, TUN со стеком `mixed` и zapret-discord-youtube 1.10.2 со стратегией EXP. При загрузке CPU около 100% игровые UDP-пакеты задерживались между TUN и Ethernet. Соединения `bf6.exe` попадали под последнее правило **«Остальное напрямую»** (`port_range=0:65535 => route(direct)`); отдельного правила Battlefield не было. Оно направляло игру без прокси-сервера, но оставляло обработку пакетов локальным sing-box.

Пассивный захват сопоставил 26 265 игровых пакетов на обоих интерфейсах. В одном матче приоритет sing-box последовательно менялся `Normal → AboveNormal → Normal`; маршруты, соединения и zapret в этом тесте не менялись.

| Приоритет sing-box | Загрузка CPU, медиана | Исходящая задержка внутри TUN, p95 | Входящая задержка внутри TUN, p95 |
| --- | --- | --- | --- |
| Normal, до изменения | 99,9% | 177,9 мс | 108,5 мс |
| AboveNormal | 99,5% | **5,4 мс** | **27,4 мс** |
| Normal, после возврата | 100% | 224,0 мс | 176,2 мс |

`p95` — задержка, в которую укладывались 95% пакетов. Это время прохождения локального участка между интерфейсами, а не полный пинг до сервера. При обычном приоритете отдельные задержки достигали 895 мс. После повышения приоритета максимальная исходящая задержка составила 21 мс, входящая — 179 мс: улучшение существенное, но отдельные выбросы остались. Контрольные UDP-пробы через Ethernet дали 0 таймаутов на 306 отправок.

Захват подтвердил задержки, но не исчезновение игровых пакетов между Ethernet и TUN: вне границ захвата несопоставленных пакетов не было. Происхождение каждого показанного игрой значения PL не установлено; потери на внешнем пути этим тестом полностью не исключены. Ограничение FPS для снижения нагрузки CPU не проверялось и не применялось.

Результат согласуется с [планированием потоков Windows по приоритетам](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling).

### Что настроено

В 64-битном реестре Windows:

```text
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sing-box.exe\PerfOptions
CpuPriorityClass = 6 (REG_DWORD, AboveNormal)
```

Параметр применяется ко всем экземплярам с именем `sing-box.exe`, независимо от папки установки. Проверены приоритет текущего процесса и начальный приоритет отдельно созданного экземпляра `sing-box.exe version`; оба — `AboveNormal`. Команда `version` завершилась, рабочий TUN продолжил работать в прежнем процессе.

Повторить настройку можно в **64-битном PowerShell от имени администратора**. Значение `6` ниже относится к параметру реестра; для работающего процесса используется именованное значение `AboveNormal`:

```powershell
$priorityKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sing-box.exe\PerfOptions'
New-Item -Path $priorityKey -Force | Out-Null
New-ItemProperty -Path $priorityKey -Name CpuPriorityClass -PropertyType DWord -Value 6 -Force | Out-Null
Get-Process -Name sing-box | ForEach-Object { $_.PriorityClass = 'AboveNormal' }
Get-Process -Name sing-box | Select-Object Id, ProcessName, PriorityClass
```

Изменение реестра задаёт приоритет будущих запусков; присваивание `PriorityClass` применяет его сразу к уже запущенным экземплярам. Reload v2rayN для этого не нужен.

### Откат на этом компьютере

До изменения параметр `CpuPriorityClass` отсутствовал, а работающий sing-box имел приоритет `Normal`. Исходное состояние записано в `%LOCALAPPDATA%\DeviceSetup\v2rayn-priority\backup.json`, результат применения — в соседнем `status.json`. Это локальные файлы компьютера, они не включены в Git.

Чтобы вернуть это исходное состояние, выполни в PowerShell от имени администратора:

```powershell
$priorityKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sing-box.exe\PerfOptions'
Remove-ItemProperty -Path $priorityKey -Name CpuPriorityClass -ErrorAction SilentlyContinue
Get-Process -Name sing-box | ForEach-Object { $_.PriorityClass = 'Normal' }
Get-Process -Name sing-box | Select-Object Id, ProcessName, PriorityClass
```

Удаляется только добавленный параметр, остальные параметры реестра сохраняются. Для другой машины с ранее заданным `CpuPriorityClass` нужно восстановить её прежнее значение.

## Доменные правила и HTTP/3

В обоих шаблонах Xray в `sniffing.destOverride` включены `http`, `tls` и `quic`. Это позволяет применять доменные правила к HTTP/3, когда TUN передаёт Xray соединение с IP-адресом назначения. Без `quic` запросы браузера по UDP могут попасть в правило «Остальное напрямую», хотя обычный HTTPS-запрос через TCP идёт через прокси. См. [документацию Xray по sniffing](https://xtls.github.io/en/config/inbound.html#sniffingobject).

Проверка HTTP 200 через `curl` подтверждает только конкретный запрос, а не загрузку приложения в браузере. При региональном редиректе проверяй также поведение браузера после Reload.

## Brevo и Claude

В обоих профилях Brevo (`brevo.com`, `sendinblue.com`) и Claude (`claude.com`, `claude.ai`, `anthropic.com`, `claudeusercontent.com`) направляются через прокси явными правилами. Они стоят выше блокировки рекламы и охватывают поддомены, включая `app.brevo.com` и `platform.claude.com`. Эти домены также добавлены в списки внешних DNS-серверов шаблона Xray.

При проверке 7 октября 2026 года со старой конфигурацией на macOS:

- `app.brevo.com` начинал отвечать HTTP 200, но загрузка обрывалась по тайм-ауту; установленный `category-ads-all` дополнительно блокировал `cdn.brevo.com`.
- `platform.claude.com/offers/startups-application` возвращал HTTP 307 на `app-unavailable-in-region?utm_source=country`. В установленном `ru-blocked` был `claude.ai`, но не `claude.com`, поэтому на этот список нельзя полагаться для всей платформы Claude.

С новыми правилами на том же VPN-сервере оба адреса полностью ответили HTTP 200. Это проверка HTTP-доступности без входа в аккаунты; доступность Claude также зависит от региона выходного IP сервера.

Чтобы применить исправление к уже настроенному v2rayN, обнови **оба поля полного шаблона Xray** и **активный профиль Routing Setting** по инструкции ниже, затем перезапусти службу и TUN. Изменение только файлов репозитория не обновляет настройки приложения.

## Настройка компьютера

1. Скачай v2rayN из [официального релиза](https://github.com/2dust/v2rayN/releases/tag/7.24.9).

   - Windows — `v2rayN-windows-64.zip`.
   - Mac с Apple Silicon — `v2rayN-macos-arm64.dmg`.
   - Mac с Intel — `v2rayN-macos-64.dmg`.

2. Запусти приложение.

   - Windows — распакуй архив и запусти `v2rayN.exe` от администратора.
   - Mac — перенеси приложение в «Программы» и открой его.

3. Добавь VPN-сервер.

   - Скопируй свою подписку или ссылку `vless://…`.
   - Выбери **Configuration / Серверы → Import Share Links from clipboard / Импорт ссылок общего доступа из буфера обмена**.
   - Для подписки открой **Subscription Group / Группа подписки → Update current subscription without proxy / Обновить текущую подписку без прокси**. Если подписка доступна только через VPN, выбери **Update current subscription with proxy / Обновить текущую подписку через прокси**.
   - Нажми правой кнопкой на нужный сервер и выбери **Set as active / Сделать активным**.

4. Настрой Geo-файлы.

   - Открой **Settings / Настройки → Option Setting / Параметры → v2rayN settings / Настройки v2rayN**.
   - В поле **Geo files source (optional) / Источник файлов Geo (необязательно)** укажи:

     ```text
     https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/{0}.dat
     ```

   - Сохрани настройки кнопкой **Confirm / Подтвердить**.
   - Открой **Help / Помощь → Check Update / Обновить**. Оставь отмеченным только **GeoFiles**, затем нажми **Check Update / Обновить**.

5. Скопируй готовый шаблон.

   - Открой **Шаблон Xray** для своей системы из таблицы выше.
   - Нажми **Raw** на GitHub.
   - Скопируй весь JSON.

6. Включи шаблон Xray.

   - Открой **Settings / Настройки → Full Config Template Setting / Настройка полного шаблона конфигурации → v2ray Full Config Template / Полный шаблон конфигурации v2ray**.
   - Включи **Enable Full Config Template / Включить полный шаблон конфигурации**.
   - Вставь одинаковый JSON в оба поля:
     - **xray config template json**.
     - **xray tun config template json**.
   - Сохрани настройки кнопкой **Confirm / Подтвердить**.

7. Настрой TUN.

   - Открой **Settings / Настройки → Option Setting / Параметры → Tun Mode settings / Настройки режима TUN**.
   - **Strict Route / Строгая маршрутизация** — выключено.

8. Исключи VPN-сервер из TUN.

   - В тех же настройках найди **Route Exclude Address / Адреса, исключаемые из маршрутизации**.
   - Добавь IP своего VPN-сервера. Ниже адрес для примера — замени его своим:

     ```text
     203.0.113.10/32
     ```

   - При смене сервера укажи его IP:
     - `/32` для IPv4.
     - `/128` для IPv6.
   - Сохрани настройки кнопкой **Confirm / Подтвердить**.

9. Импортируй правила для TUN.

   - Открой **Правила Routing Setting** для той же системы из таблицы выше, нажми **Raw** и скопируй JSON.
   - Открой **Settings / Настройки → Routing Setting / Настройки маршрутизации**. Создай отдельный профиль с названием `device-setup-windows` или `device-setup-macos`.
   - В редакторе профиля импортируй правила из буфера обмена, сохрани и выбери этот профиль активным. При повторном импорте замени прежний список целиком, чтобы не оставить старые правила выше новых.
   - В режиме TUN sing-box использует этот профиль перед передачей трафика Xray. Правила процессов (`Discord.exe` в Windows, `Discord` и его вспомогательные процессы в macOS) покрывают в том числе голосовые соединения без домена.

10. Включи защищённый DNS для TUN.

   - В **Settings / Настройки → DNS settings** полностью замени содержимое **Domestic DNS** и **Remote DNS** на `https://1.1.1.1/dns-query`; **Bootstrap DNS** — на `1.1.1.1`.
   - При включённом TUN обычные DNS-запросы идут через HTTPS даже для `direct`: это обход прокси, а не отключение шифрования DNS. Без TUN отдельно настрой защищённый DNS в системе.

11. Включи VPN.

   - Нажми **Reload / Перезапустить службу**.
   - Включи **Enable Tun / Включить TUN**.
   - Если TUN уже включён, выключи и снова включи **Enable Tun / Включить TUN**.
