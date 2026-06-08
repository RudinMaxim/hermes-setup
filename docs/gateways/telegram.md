# Telegram gateway

Ежедневный доступ к Hermes через Telegram-бота. Настраивается через
`config/gateways.toml`; токен и allowlist лежат в `config/.env`.

## 1. Создать бота (вручную, в Telegram)

1. Открой чат с [@BotFather](https://t.me/BotFather).
2. Отправь `/newbot`, выбери имя и username, который оканчивается на `bot`.
3. BotFather вернёт **HTTP API token** вида `123456789:AAH...`. Храни его в секрете.

## 2. Узнать свой numeric user ID (вручную)

Allowlist задаётся по **числовому user ID**, а не по @username
(default-deny — всё, что не перечислено, игнорируется).

1. Открой чат с [@userinfobot](https://t.me/userinfobot) (или @RawDataBot).
2. Он ответит твоим `Id:` — числом вроде `111222333`.
3. Повтори для каждого человека, которому нужен доступ, и соедини ID через запятую.

## 3. Настроить

Можно дать скрипту спросить недостающие значения в интерактивном режиме, либо
заполнить файлы вручную.

**Интерактивно:** запусти `./setup.sh` (или `./scripts/setup-gateway.sh`) в
терминале — если токен или allowlist отсутствуют, скрипт спросит их и запишет в
`config/.env` (токен вводится скрыто, не печатается на экран).

**Вручную:** добавь в `config/.env`:
```
TELEGRAM_BOT_TOKEN=123456789:AAH...
TELEGRAM_ALLOWED_USERS=111222333,444555666
```
и включи gateway в `config/gateways.toml`:
```toml
[telegram]
enabled = true
```

## 4. Применить

```bash
./scripts/setup-gateway.sh
```
Скрипт проверяет токен (`getMe`), убеждается, что allowlist числовой, а затем
пересоздаёт контейнер с командой gateway. В образе Hermes уже задан `hermes`
как entrypoint, поэтому override должен быть таким:

```yaml
command: ["gateway", "run"]
```

Не используй `command: ["hermes", "gateway", "run"]`: это разворачивается в
`hermes hermes gateway run`, и контейнер падает с ошибкой
`invalid choice: 'hermes'`.

Отправь сообщение боту и проверь, что он отвечает. Повторный запуск безопасен:
если ничего не изменилось, скрипт только выведет `[SKIP]`.

Если gateway уже запущен, но ты изменил `config/.env` или `Hermes`-конфиг
`/opt/data/config.yaml`, принудительно пересоздай контейнер gateway:

```bash
./scripts/setup-gateway.sh --restart
```

Без `--restart` уже запущенный gateway напишет `[SKIP]`: это значит только, что
команда контейнера уже `gateway run`, но свежий конфиг не перечитывался.

Скрипт также проверяет сломанные состояния gateway. Если он видит старую
дублированную команду (`hermes gateway run`), остановленный контейнер или
ошибку `hermes gateway status`, он пересоздаёт контейнер вместо ложного `[SKIP]`.

## Google Drive / Workspace из Telegram

### Проверенная рабочая схема

Для Telegram используй встроенный Google Workspace skill, а не remote
`google_drive` MCP. Remote MCP использует отдельный OAuth и может снова просить
авторизацию, даже если Workspace skill уже читает Drive.

Рабочая схема:

1. Один раз авторизуй Google Workspace через CLI-чат Hermes.
2. Убедись, что появился `/opt/data/google_token.json`.
3. Запусти стабилизатор:

```bash
./scripts/stabilize-google-workspace.sh
```

После этого в Telegram формулируй запрос явно:

```text
Используй Google Workspace skill. Покажи последние 5 файлов из моего Google Drive.
```

Если контейнер gateway пересоздавался или Telegram снова просит Google OAuth,
повтори:

```bash
./scripts/stabilize-google-workspace.sh
```

Если Google Drive работает в `docker exec -it hermes hermes chat`, но Telegram
бот снова просит авторизацию, обычно причина в том, что одновременно включены
две Google-интеграции:

- встроенный Google Workspace skill, у которого уже есть токен;
- remote `google_drive` MCP, у которого свой отдельный OAuth flow.

Для стабильной работы Telegram используй Workspace skill и отключи remote
`google_drive` MCP. Запусти:

```bash
./scripts/stabilize-google-workspace.sh
```

Скрипт проверяет наличие Workspace token, создаёт legacy token path, отключает
`mcp_servers.google_drive.enabled`, проверяет Hermes config и перезапускает
Telegram gateway.

CLI-авторизация Google Workspace сохраняет токен здесь:

```text
/opt/data/google_token.json
```

Некоторые проверки Workspace skill всё ещё смотрят на старый путь:

```text
/home/hermes/.hermes/google_token.json
```

После успешной CLI-авторизации один раз запусти настройку gateway:

```bash
./scripts/setup-gateway.sh
```

Если `/opt/data/google_token.json` существует, скрипт создаст внутри контейнера
compatibility symlink:

```text
/home/hermes/.hermes/google_token.json -> /opt/data/google_token.json
```

Потом попробуй бота ещё раз. Если ты также менял `config/.env` или
`/opt/data/config.yaml`, используй:

```bash
./scripts/setup-gateway.sh --restart
```

Проверка вручную:

```bash
docker exec hermes sh -lc 'echo HOME=$HOME; echo HERMES_HOME=$HERMES_HOME'
docker exec hermes sh -lc 'ls -l /opt/data/google_token.json /home/hermes/.hermes/google_token.json'
docker exec hermes hermes gateway status
```

Выключить можно так: поставь `enabled = false` и запусти скрипт снова — контейнер
вернётся в idle/CLI mode.

## Запрос home channel

После запуска Telegram gateway Hermes может прислать такое сообщение:

```text
No home channel is set for Telegram. A home channel is where Hermes delivers cron job results and cross-platform messages.

Type /sethome to make this chat your home channel, or ignore to skip.
```

Это не ошибка авторизации и не проблема MCP. Hermes спрашивает, какой Telegram-чат
должен получать фоновые сообщения: результаты cron job, запланированные задачи и
сообщения, созданные вне текущего чата.

Если это приватный чат с ботом, отправь:

```text
/sethome
```

Если используешь группу, отправь `/sethome` в этой группе. Если фоновая доставка
не нужна, запрос можно игнорировать, но Hermes может напомнить снова.

## Личное управление + групповая доставка

Если хочешь управлять Hermes только из личного DM, но отправлять командные
обновления в Telegram-группу, используй группу как Hermes home channel.

Рекомендуемая схема:

1. Оставь в `config/.env` только свой numeric Telegram user ID:

```env
TELEGRAM_ALLOWED_USERS=111222333
```

2. Перезапусти gateway, чтобы allowlist прочитался заново:

```bash
./scripts/setup-gateway.sh --restart
```

3. В Telegram-группе, куда бот должен писать обновления, отправь:

```text
/sethome
```

После этого работай с Hermes через личный чат с ботом. В запросах явно проси
отправлять командные сообщения в home channel и оставлять личную версию в DM:

```text
Используй skill project-docs-telegram.

Обнови проект в Google Docs без дубля.
Команде отправь апдейт в home channel без стоимости.
Мне в личку отправь версию со стоимостью.
```

Для этой схемы не нужно выключать Telegram privacy mode. Оставь privacy mode
включённым и не делай бота админом группы, если хочешь, чтобы он игнорировал
обычный групповой чат. В этом режиме бот получает:

- личные DM-сообщения;
- group commands, явно адресованные ему;
- сообщения с `@mention` и ответы на его собственные сообщения;
- исходящие сообщения, которые он отправляет в home channel.

Это даёт именно нужное разделение: ты управляешь Hermes в личке, рабочая группа
остаётся тихой, пока ты не упомянешь бота, а Hermes при этом может публиковать
сообщения в группу.

Чтобы этот режим был включён постоянно, в Hermes config должен быть флаг:

```yaml
telegram:
  require_mention: true
```

`./scripts/setup-hermes.sh` теперь включает этот флаг по умолчанию при
инициализации `config.yaml`.

## Режимы работы

Ниже зафиксированы основные сценарии, чтобы было понятно, что именно
отвечает за входящие сообщения, а что за исходящие публикации.

| Режим | Как ты управляешь Hermes | Что он делает в группе | Что настроить |
|---|---|---|---|
| Личка-only | Только через DM с ботом | В группе молчит | `TELEGRAM_ALLOWED_USERS`, `privacy mode = Enable`, `telegram.require_mention = true` |
| Личка + mention-only группа | DM + `@botname` в рабочей группе | Отвечает только на `@mention` и ответы на свои сообщения | То же самое, плюс не делать бота админом |
| Личка + group delivery | DM для управления, группа как `home channel` | В группе публикует исходящие апдейты, но не обязан отвечать на каждый обычный пост | `TELEGRAM_ALLOWED_USERS`, `/sethome` в нужной группе, `telegram.require_mention = true` |
| Полный групповой режим | DM или группа | Читает обычные сообщения группы | `@BotFather → /setprivacy → Disable`, вручную отключить `telegram.require_mention` |

По умолчанию в этом репозитории включён именно mention-only режим для входящих
сообщений. Это безопаснее для рабочих групп и даёт понятное разделение:

- личка — для команд и контроля;
- `@mention` — для адресных запросов в рабочей группе;
- `home channel` — для отправки исходящих апдейтов;
- полный group-read режим — только если он действительно нужен и ты готов
  сознательно расширить поверхность ответов.

Если ты вручную отключишь `telegram.require_mention`, следующий запуск
`./scripts/setup-hermes.sh` вернёт его обратно. Это сделано намеренно: для
рабочих групп безопаснее держать mention-only режим как базовый.

Быстрая проверка:

1. Отправь боту DM и убедись, что он отвечает там.
2. В рабочей группе отправь обычное сообщение без упоминания. Бот должен молчать.
3. В рабочей группе отправь `@<botname> ...`. Бот должен отреагировать.
4. Отправь `/sethome` в группе, если именно эта группа должна получать исходящие обновления.

Официальные ссылки:

- Документация Hermes по Telegram: `/sethome` можно назначить для любого Telegram DM или группы.
- Telegram Bot API docs: privacy mode определяет, какие сообщения из группы бот видит; приватные сообщения бот получает всегда.

## Privacy mode в группах (вручную)

По умолчанию бот в группе видит только сообщения, которые начинаются с `/`
(Telegram privacy mode). Также он получает `@mention` и ответы на свои сообщения.
Чтобы бот видел все сообщения группы: @BotFather → `/setprivacy` → выбери бота
→ **Disable**. Numeric allowlist всё так же фильтрует отправителей и в группах,
и в личных сообщениях.
