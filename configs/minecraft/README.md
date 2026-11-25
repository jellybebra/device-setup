# Minecraft Java 26.2

Paper 26.2 build 135, WorldEdit 7.4.6 и AuthMe Reloaded 6.0.1. Обычный мир, выживание, сложность normal. Прорисовка 12 чанков, симуляция 5. Контейнеру выделено до 3 ГиБ, из них до 2304 МиБ под Java heap.

## Первый запуск на Ubuntu

В каталоге с `compose.yaml` выполните:

```sh
sudo systemctl enable --now docker
docker compose up -d --wait --wait-timeout 600
docker compose exec minecraft rcon-cli plugins
```

Игровой порт изначально доступен на loopback. Проверьте, что AuthMe и WorldEdit активны. Зарегистрируйте SquirtBoss в AuthMe из интерактивной консоли, затем выдайте OP. Используйте отдельный игровой пароль.

```sh
docker compose exec minecraft rcon-cli
```

```text
authme register SquirtBoss <игровой-пароль>
minecraft:op SquirtBoss
```

После подтверждения регистрации и выдачи OP добавьте `MC_BIND=0.0.0.0` в локальный файл `.env` и выполните `docker compose up -d --wait`. В сетевом экране провайдера разрешите TCP 25565. В Cloudflare создайте A-запись `minecraft.example.com` с IPv4 сервера в режиме **DNS only**. Игроки регистрируются через `/register пароль пароль`, затем входят через `/login пароль`.

Мир, база AuthMe и список операторов хранятся в томе Compose `game`. Docker запускает контейнер после перезагрузки хоста. При ручной остановке через `docker compose stop` вернуть сервер в автозапуск можно командой `docker compose up -d`.
