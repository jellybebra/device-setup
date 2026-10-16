# Как вручную добавить Proton в Clash Verge

Proton пока не подключён. Эта инструкция добавляет его как альтернативу в
группу **VPN — выход в интернет**, сохраняя YouTube/Discord и остальные прямые правила.

1. В [кабинете Proton](https://account.protonvpn.com/) открой
   **Downloads → WireGuard configuration**, создай отдельную конфигурацию
   `windows-clash`, выбери сервер и скачай `.conf`.
   Серверный `/opt/vless/secrets/proton-us.conf` уже используется VLESS:
   не запускай тот же ключ одновременно на ПК. [Инструкция Proton](https://protonvpn.com/support/wireguard-configurations).
2. Сохрани `.conf` вне Git, например в `%USERPROFILE%\.device-setup\proton\`.
   В Clash открой **Profiles → device-setup → Edit File** и сначала сохрани
   резервную копию профиля вне Git. Оба файла содержат приватные ключи.
3. Текущий профиль записан как JSON (допустимый YAML). В массив `proxies`
   добавь объект ниже, отделив его запятой от предыдущего объекта.
   Замени все значения-заглушки данными из `.conf`:

   ```json
   {
     "name": "Proton",
     "type": "wireguard",
     "server": "PROTON_ENDPOINT_IP",
     "port": 51820,
     "ip": "PROTON_INTERFACE_IPV4",
     "private-key": "PROTON_INTERFACE_PRIVATE_KEY",
     "public-key": "PROTON_PEER_PUBLIC_KEY",
     "udp": true,
     "mtu": 1280,
     "persistent-keepalive": 25
   }
   ```

   | Поле объекта | Откуда взять |
   | --- | --- |
   | `server`, `port` | `[Peer] Endpoint`, разделить адрес и порт; порт 51820 в примере заменить фактическим |
   | `ip` | IPv4 из `[Interface] Address`, без `/32` |
   | `private-key` | `[Interface] PrivateKey` |
   | `public-key` | `[Peer] PublicKey` |
   | `mtu` | `[Interface] MTU`, если указан; иначе оставить 1280 |
   | `persistent-keepalive` | `[Peer] PersistentKeepalive`, если указан; иначе оставить 25 |

   Если есть `PresharedKey`, добавь `"pre-shared-key": "значение"`.
   DNS оставь текущий: профиль использует DoH через выбранный VPN; DNS из
   Proton-конфига здесь не импортируется. Не копируй строки PostUp/PostDown.
4. В `proxy-groups` найди объект с `"name": "VPN — выход в интернет"`
   и добавь `"Proton"` в конец его массива `proxies`, сохранив все существующие
   элементы. В старом профиле эта группа называется `VPN`.
   Группы пути до сервера и массив `rules` не меняй.
5. Сохрани файл и выполни **Reactivate Profiles**. Если ядро сообщает ошибку,
   исправь JSON или восстанови копию. После успешного применения открой
   **Proxies → VPN — выход в интернет → Proton**. Проверяй новый запрос к сайту из VPN-правил,
   например ChatGPT: обычный сайт проверки IP может идти DIRECT и показывать
   домашний IP. Уже открытые соединения могут сохранять старый выход.
6. Чтобы вернуться к прямому VLESS, выбери **VPN — выход в интернет → Мой сервер · VLESS**,
   затем **VLESS — путь до сервера → Напрямую**. TUN и System Proxy оставь включёнными.

Если прямой WireGuard до Proton не соединяется, можно попробовать добавить
в объект Proton `"dialer-proxy": "WARP"`, повторно применить профиль и перезапустить
ядро. Это даст цепочку ПК → WARP → Proton; её в этой задаче не проверяли.
Сам по себе выбор Proton не меняет правила DIRECT для YouTube/Discord.

Для генерации нового профиля с нуля есть `mihomo/build_profile.py --proton <file.conf>`.
Он читает политику из репозитория, а не текущие ручные правки GUI, поэтому
для уже настроенного профиля выше описано точечное добавление.
