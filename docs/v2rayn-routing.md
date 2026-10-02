# v2rayN 7.24.9

## Профили компьютеров

| Профиль | Google / YouTube | Discord, включая голос | Правила Routing Setting | Шаблон Xray |
| --- | --- | --- | --- | --- |
| Windows | Напрямую | Напрямую | [windows/routes.json](../configs/v2rayn/windows/routes.json) | [windows/xray-template.json](../configs/v2rayn/windows/xray-template.json) |
| macOS | Через прокси | Через прокси | [macos/routes.json](../configs/v2rayn/macos/routes.json) | [macos/xray-template.json](../configs/v2rayn/macos/xray-template.json) |

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
   - Открой **Help / Помощь → Check Update / Обновить**. Для обновления Geo-файлов оставь отмеченным только **GeoFiles**, затем нажми **Check Update / Обновить**.

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
