[← К навигации](../README.md)

# v2rayN на новом компьютере

Windows и macOS, v2rayN 7.24.9, ядро Xray.

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
   - Выбери **Импорт из буфера обмена**.
   - Для подписки выполни её обновление.
   - Выбери нужный сервер активным.
   - Для VLESS используй ядро **Xray**.

4. Настрой Geo-файлы.

   - Открой **Settings → Option Setting → v2rayN settings**.
   - Укажи источник Geo-файлов:

     ```text
     https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/{0}.dat
     ```

   - Сохрани настройки.
   - Выполни **Обновить Geo-файлы** и **Обновить Xray**.

5. Скопируй готовый шаблон.

   - Открой [xray-template.json](../configs/v2rayn/xray-template.json).
   - Нажми **Raw**.
   - Скопируй весь JSON.

6. Включи шаблон Xray.

   - Открой **Settings → Full Config Template Setting → Xray**.
   - В русском интерфейсе — «Настройка полного шаблона конфигурации».
   - Включи шаблон.
   - Вставь одинаковый JSON в оба поля:
     - **Xray config template**.
     - **Xray TUN config template**.
   - Оставь **Add proxy only** выключенным.
   - Сохрани настройки.

7. Настрой TUN.

   - Открой **Settings → Option Setting → TUN**.
   - **Auto Route** — включено.
   - **Strict Route** — выключено.
   - **Stack** — `mixed`.
   - **MTU** — `9000`.
   - **IPv6** — выключено.
   - **Legacy TUN Protect** — включено.

8. Исключи VPN-сервер из TUN.

   - В тех же настройках найди **Route Exclude Address**.
   - В русском интерфейсе — «Исключённые адреса маршрутов».
   - Добавь IP текущего VPN-сервера:

     ```text
     92.246.139.113/32
     ```

   - При смене сервера укажи его IP:
     - `/32` для IPv4.
     - `/128` для IPv6.
   - Сохрани настройки.

9. Включи VPN и проверь соединение.

   - Нажми **Reload**.
   - Включи **TUN**.
   - Разреши приложению создать VPN-интерфейс.
   - Если TUN уже включён, выключи и включи его снова.
   - Проверь ChatGPT и голосовой канал Discord.

## Готовый шаблон

- Правила из [routes.json](../configs/v2rayn/routes.json) уже включены.
- Порт `7844` направляется через прокси.
- Добавлены исключения сниффинга:
  - `h2.cftunnel.com`.
  - `probe.cftunnel.com`.
  - `quic.cftunnel.com`.
- Отдельно импортировать routing не нужно.
- DNS и маршруты редактируй в шаблоне.
- VPN-сервер выбирай в главном окне.

## Прокси-сервер

- На VPS один раз настрой такие же исключения по [инструкции для 3x-ui](https://github.com/jellybebra/vless-docker#cloudflare-tunnel).
- На текущем сервере это уже сделано.
