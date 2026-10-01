# v2rayN 7.24.9

## Настройка компьютера

Названия элементов интерфейса указаны в формате **English / Русский**. Если название одинаково в обоих языках интерфейса, оно указано один раз.

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

   - Открой [xray-template.json](../configs/v2rayn/xray-template.json).
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

9. Включи VPN.

   - Нажми **Reload / Перезапустить службу**.
   - Включи **Enable Tun / Включить TUN**.
   - Если TUN уже включён, выключи и снова включи **Enable Tun / Включить TUN**.
