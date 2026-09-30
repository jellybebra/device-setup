[← К навигации](../README.md)

# v2rayN на новом компьютере

Windows и macOS, v2rayN 7.24.9, ядро Xray.

## Настройка компьютера

1. Скачай v2rayN из [официального релиза](https://github.com/2dust/v2rayN/releases/tag/7.24.9): Windows — `v2rayN-windows-64.zip`, Mac с Apple Silicon — `v2rayN-macos-arm64.dmg`, Mac с Intel — `v2rayN-macos-64.dmg`.
2. На Windows распакуй архив и запусти `v2rayN.exe` от администратора. На Mac перенеси приложение в «Программы» и открой его.
3. Скопируй свою подписку или ссылку `vless://…` и выбери **Импорт из буфера обмена**. Для подписки выполни её обновление. Выбери нужный сервер активным; для VLESS используй ядро **Xray**.
4. Открой **Settings → Option Setting → v2rayN settings** и укажи источник Geo-файлов:

   ```text
   https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/{0}.dat
   ```

   Сохрани и выполни **Обновить Geo-файлы** и **Обновить Xray**.
5. Открой [xray-template.json](../configs/v2rayn/xray-template.json), нажми **Raw** и скопируй весь JSON.
6. В v2rayN открой **Settings → Full Config Template Setting → Xray** («Настройка полного шаблона конфигурации»). Включи шаблон, вставь одинаковый JSON в поля **Xray config template** и **Xray TUN config template**. Оставь **Add proxy only** выключенным и сохрани.
7. В **Settings → Option Setting → TUN** выставь: **Auto Route — включено**, **Strict Route — выключено**, **Stack — mixed**, **MTU — 9000**, **IPv6 — выключено**, **Legacy TUN Protect — включено**.
8. Там же в **Route Exclude Address / исключённые адреса маршрутов** добавь IP текущего VPN-сервера:

   ```text
   92.246.139.113/32
   ```

   При смене сервера укажи его IP: `/32` для IPv4, `/128` для IPv6. Сохрани.
9. Нажми **Reload**, включи **TUN** и разреши приложению создать VPN-интерфейс. Если TUN уже включён, выключи и включи его снова. Проверь ChatGPT и голосовой канал Discord.

В шаблоне уже есть правила из [routes.json](../configs/v2rayn/routes.json), порт `7844` через прокси и исключения `h2.cftunnel.com`, `probe.cftunnel.com`, `quic.cftunnel.com`. Отдельно импортировать routing не нужно. DNS и маршруты редактируй в шаблоне; VPN-сервер выбирай в главном окне.

На VPS один раз настрой такие же исключения по [инструкции для 3x-ui](https://github.com/jellybebra/vless-docker#cloudflare-tunnel). На текущем сервере это уже сделано.
