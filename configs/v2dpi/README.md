# Профили V2DPI для macOS

Каждый файл содержит один профиль. В окне «Профили» создайте копию, откройте её редактор, нажмите «Открыть файл…» и «Проверить и применить». Для маршрутов через VLESS используется сервер, выбранный в приложении.

| Профиль | Особенность |
| --- | --- |
| [По умолчанию](default.json) | Прямой маршрут для статики GitHub. |
| [githubassets → VLESS](github-assets-vless.json) | Статика GitHub идёт через VLESS, включён быстрый повтор TCP-подключения к VLESS-серверу. |
| [YouTube VLESS](youtube-vless.json) | YouTube и видеосерверы идут через VLESS. |
| [YouTube TCP, короткое окно](youtube-short-window.json) | Прямой YouTube по TCP с малым начальным окном. |
| [YouTube автокэш](youtube-autocache.json) | Прямой YouTube с запоминанием имён видеосерверов для следующих TCP-подключений. |
| [YouTube без местных кэшей (DNS и TCP)](youtube-skip-local-caches.json) | Прямой YouTube с исключением четырёх групп кэшей по DNS и имени в TCP-соединении. Для Twitch запросы к `usher.ttvnw.net` и `gql.twitch.tv` идут через VLESS, остальные домены Twitch из списка идут напрямую. |

Четыре варианта для YouTube наследуют настройки профиля «githubassets → VLESS». Для вариантов с автокэшем и исключением местных кэшей нужна сборка с поддержкой `--wssize-ramp` и `youtubeStartupRetry`. [V2DPI для macOS](../../apps/zapret-local/)
