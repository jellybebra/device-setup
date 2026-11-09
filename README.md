# Device Setup

Конфигурации домашних устройств. Сетевые правила зависят от точки подключения: например, Cloudflare Tunnel
на Cudy выходит напрямую, а профиль v2rayN может отправить его через VLESS.

| Устройство или задача | Что здесь хранится |
| --- | --- |
| [Cudy TR3000](docs/cudy-tr3000.md) | Раздельные маршруты PassWall2 и zapret2, основной и резервный DoH, ограничения прошивки |
| [Huawei AX3](docs/huawei-ax3.md) | Профиль VLESS для debug-прошивки, прямой игровой UDP, совместимая сборка Xray |
| [v2rayN на Windows и macOS](docs/v2rayn-routing.md) | Различия клиентских профилей, исключения TUN и маршрутизация через Zapret Local |
| [Happ на iPhone](docs/happ-ios.md) | Локальный профиль маршрутизации, серверная подписка и условия входа по passkey |
| [Zapret Local](apps/zapret-local/README.md) | Самостоятельный TUN для macOS с правилами Cudy, DPI и VLESS |

**Windows:** [набор приложений после переустановки](docs/windows-reinstall.md),
[голосовой ввод Chrome](docs/chrome-voice-windows.md), [Vencord](docs/vencord.md),
[Minecraft и UPnP](docs/upnp-windows.md), [системные файлы и приложения Xbox](docs/windows.md).

**macOS:** [действие Finder для скачанных приложений](docs/macos.md).
