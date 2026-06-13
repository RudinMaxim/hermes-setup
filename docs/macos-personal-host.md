# Hermes на персональном Mac mini

Этот режим запускает Hermes нативно на выделенном Mac mini. VPS/Docker setup
остаётся отдельным вариантом и для этой машины не нужен.

## Архитектура

- Hermes Agent работает из `~/.hermes`.
- Telegram gateway работает как пользовательский `launchd` service.
- основной профиль использует OpenRouter;
- команда `hermes-ollama` использует локальную модель Ollama;
- Todoist подключён к официальному remote MCP через OAuth;
- Obsidian доступен через официальный filesystem MCP, ограниченный vault;
- Playwright MCP использует отдельный постоянный Chrome profile;
- Obsidian vault находится в отдельном Git-репозитории;
- `launchd` каждые 5 минут коммитит локальные изменения, подтягивает remote
  через rebase и отправляет результат обратно.

## Установка

```bash
cp config/macos.env.example config/macos.env
nano config/macos.env
make setup-macos
```

Файл `config/macos.env` содержит локальные пути и секреты, поэтому исключён из
Git. Telegram token остаётся в `~/.hermes/.env`.

Проверка:

```bash
hermes status
hermes gateway status
hermes-ollama -z "Ответь одним словом: работает"
hermes mcp list
hermes mcp test obsidian
hermes mcp test playwright
make check-multimedia
launchctl print "gui/$(id -u)/ai.hermes.obsidian-sync"
tail -n 100 ~/Library/Logs/hermes/obsidian-sync.log
```

## Health-check и автозапуск Ollama

`setup-macos.sh` устанавливает два пользовательских `launchd` job:

- `ai.hermes.ollama-watchdog` каждую минуту проверяет Ollama API и открывает
  Ollama app, если сервис недоступен;
- `ai.hermes.health-check` каждые 15 минут проверяет Hermes gateway, Ollama и
  выбранную модель, Todoist MCP, Obsidian MCP/Git, Google Workspace и Telegram.

Health-check отправляет сообщение в Telegram только при появлении новой ошибки,
изменении набора ошибок или восстановлении. Поэтому штатные успешные проверки
не создают сообщения. Токен читается из `~/.hermes/.env` и не записывается в
plist.

Ручная проверка:

```bash
make health-macos
launchctl print "gui/$(id -u)/ai.hermes.ollama-watchdog"
launchctl print "gui/$(id -u)/ai.hermes.health-check"
tail -n 100 ~/Library/Logs/hermes/health-check.log
tail -n 100 ~/Library/Logs/hermes/health-check.error.log
```

Интервалы и chat ID задаются в `config/macos.env`:

```env
OLLAMA_WATCH_INTERVAL=60
HERMES_HEALTH_INTERVAL=900
HEALTHCHECK_TELEGRAM_CHAT_ID=745637014
```

## Стабильные обновления

Автоматическое бесконтрольное обновление Hermes отключено. Проверка и
применение разделены:

```bash
make check-update-macos
make update-macos
```

`check-update-macos` не меняет установку. `update-macos` требует чистый Hermes
checkout, запоминает текущие version/commit, запускает штатный
`hermes update --backup`, повторно устанавливает managed safety wrapper,
перезапускает gateway и проверяет core-сервисы. Если gateway или Ollama после
обновления не работают, скрипт автоматически возвращает прежний commit,
переустанавливает зависимости и wrapper, затем снова запускает gateway.
Временный сбой внешнего Todoist/Google/Telegram не вызывает откат, но
показывается последующим полным health-check.

Проверенная версия хранится в `HERMES_EXPECTED_VERSION`, ветка обновлений — в
`HERMES_UPDATE_BRANCH`. После успешного осознанного обновления значение версии
следует изменить в локальном `config/macos.env` и в example отдельным коммитом.

## Telegram

Штатная команда Hermes устанавливает `~/Library/LaunchAgents/ai.hermes.gateway.plist`.
Allowlist должен содержать только numeric Telegram user IDs. После изменения
token или allowlist:

```bash
hermes gateway restart
```

## Google Calendar

Calendar подключается встроенным `google-workspace` skill. Для Telegram это
стабильнее отдельного remote Google MCP: один OAuth token используется CLI и
gateway.

1. В Google Cloud создай OAuth Client ID типа **Desktop app**.
2. Включи Google Calendar API. Если приложение в Testing, добавь свой Google
   аккаунт в Test users.
3. Скачай client secret JSON.
4. Выполни:

```bash
HPY="$HOME/.hermes/hermes-agent/venv/bin/python"
GSETUP="$HOME/.hermes/hermes-agent/skills/productivity/google-workspace/scripts/setup.py"
"$HPY" "$GSETUP" --client-secret ~/Downloads/client_secret.json
"$HPY" "$GSETUP" --auth-url
```

Открой выданный URL. После редиректа на неработающий `localhost:1` скопируй
весь URL из адресной строки:

```bash
"$HPY" "$GSETUP" --auth-code "http://localhost:1/?code=..."
"$HPY" "$GSETUP" --check-live
```

Hermes `v0.15.0` запрашивает полный Workspace scope set: Gmail, Calendar,
Drive, Contacts, Sheets и Docs. Встроенная документация этой версии упоминает
`--services calendar`, но фактический `setup.py` этот аргумент ещё не
поддерживает. Не запускай setup через Homebrew `python3`: PEP 668 блокирует
автоматическую установку зависимостей; используй Hermes venv как выше.

Создание и удаление событий должно оставаться подтверждаемой операцией.

Текущий Desktop OAuth client:
`375597971319-9juig1f7kf4h2fpc3uauuvams286hqgm.apps.googleusercontent.com`,
проект `rapid-airship-499220-t2`.

Рабочее состояние на этом Mac mini:

- Audience: **External**;
- Publishing status: **Testing**;
- test user: `maxrudin2004@gmail.com`;
- token: `~/.hermes/google_token.json`;
- `setup.py --check-live`: `LIVE_CHECK_OK`.

Публиковать приложение не требуется: для персонального использования достаточно
режима Testing и добавленного test user. Ошибка `403 org_internal` означает, что
Audience снова стал Internal либо используется OAuth client из другого проекта.
После изменения Audience всегда создавай новую OAuth URL: pending state,
authorization code и URL одноразовые. Полные callback URL и authorization codes
не записывай в Git.

## Todoist MCP

Используется официальный Doist endpoint:

```text
https://ai.todoist.net/mcp
```

`setup-macos.sh` устанавливает managed wrapper
`~/.local/bin/hermes`. Он не меняет upstream checkout и переживает штатные
обновления Hermes.

Первичная авторизация:

```bash
hermes mcp login todoist
hermes mcp test todoist
```

OAuth открывается в браузере. API token в `config/macos.env` не хранится.
Создание, завершение и удаление задач следует считать изменяющими операциями и
подтверждать перед выполнением.

OAuth credentials хранятся в `~/.hermes/mcp-tokens/`; access token обновляется
через refresh token автоматически. Повторный браузерный вход нужен только после
отзыва доступа или ошибки `invalid_grant`, а не после обычного сетевого сбоя.
Access token может жить около часа — это штатно и не означает, что интеграция
отключилась.

При существующем token-файле `hermes mcp login todoist` через managed wrapper
выполняет безопасный `mcp test`: проверяет соединение и позволяет SDK обновить
access token, не удаляя refresh token. Для смены аккаунта/scopes или реального
`invalid_grant` используй:

```bash
hermes mcp login todoist --force
```

Перед forced login wrapper сохраняет token, client registration и OAuth
metadata. Если callback отменён, истёк по таймауту или завершился ошибкой,
прежний комплект восстанавливается автоматически.

Hermes имеет встроенный circuit breaker: после трёх последовательных ошибок
Todoist блокируется примерно на 60 секунд, затем следующий вызов автоматически
проверяет соединение и закрывает breaker при успехе. Ручной `mcp login` для
этого не нужен.

Для общего обзора вызывай `get-overview` без `projectId`. Переданный пустой,
неполный или выдуманный project ID приводит к Todoist
`INVALID_ARGUMENT_VALUE`; повторение такого же вызова может открыть circuit
breaker. Для конкретного проекта сначала получи реальный ID через
`find-projects`.

`setup-macos.sh` добавляет эти правила в `telegram.channel_prompts` для
разрешённых Telegram chats, поэтому gateway получает их как system prompt.

Диагностика без повторной авторизации:

```bash
hermes mcp test todoist
```

Если нужно немедленно сбросить состояние gateway, не ожидая cooldown:

```bash
hermes gateway restart
```

## Playwright MCP

`setup-macos.sh` системно регистрирует официальный `@playwright/mcp` с
постоянным профилем:

```text
~/.hermes/playwright-profile
```

Это отдельный Chrome profile: он не блокируется обычным запущенным Chrome и
сохраняет авторизацию между рестартами MCP. Версия пакета закреплена переменной
`HERMES_PLAYWRIGHT_MCP_VERSION` в `config/macos.env`.

После добавления или изменения MCP уже работающий agent должен перечитать
tools. Используй `/reload-mcp` в Telegram/CLI chat либо:

```bash
hermes gateway restart
```

Проверка:

```bash
hermes mcp test playwright
```

## Gateway status на macOS

Источником истины для LaunchAgent является domain-scoped команда:

```bash
launchctl print "gui/$(id -u)/ai.hermes.gateway"
```

Legacy-вызов `launchctl list ai.hermes.gateway` на новых macOS может сообщить,
что service не загружен, хотя job работает в `gui/<uid>`. Managed wrapper
сверяет `hermes gateway status` с `launchctl print` и исправляет этот ложный
negative, не меняя upstream Hermes checkout.

## Obsidian и Git

Hermes использует `OBSIDIAN_VAULT_PATH` из `~/.hermes/.env`. Для локального
vault setup также добавляет официальный
`@modelcontextprotocol/server-filesystem`, которому передаётся только путь
vault. Встроенный `obsidian` skill задаёт правила работы с Markdown, а MCP
ограничивает filesystem surface одним репозиторием.

Filesystem MCP устанавливается из официального npm-пакета:
`@modelcontextprotocol/server-filesystem`.

Синхронизация выполняет:

1. `git add -A` и commit локальных изменений;
2. `git fetch`;
3. `git rebase origin/main`;
4. `git push`;
5. повторяет fetch/rebase/push при одновременном push с другого устройства.

Конфликт не разрешается автоматически. Скрипт abort-ит rebase и пишет ошибку в
`~/Library/Logs/hermes/obsidian-sync.error.log`, не выбирая одну версию заметки
за пользователя.

На каждом другом устройстве нужна симметричная дисциплина: перед редактированием
подтянуть изменения, после редактирования commit/push. Чем короче интервал
синхронизации, тем меньше вероятность конфликта.

Ручной запуск:

```bash
set -a
source config/macos.env
set +a
./scripts/macos/sync-obsidian.sh
```

## Ollama

Профиль `ollama` изолирован от основного профиля и доступен командой:

```bash
hermes-ollama
```

Его параметры задаются в `config/macos.env`:

```env
OLLAMA_MODEL=gemma4:e2b
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1
```

Ollama app должна запускаться при входе пользователя в macOS. Локальная модель
не заменяет основной профиль: Telegram по умолчанию продолжает использовать
основной OpenRouter-профиль, а локальный inference запускается явно через
`hermes-ollama`.

## Голос, изображения и видео

`setup-macos.sh` настраивает:

- локальное STT через Homebrew `openai-whisper`, модель `base`, язык `ru`;
- нативное TTS через системный голос macOS `Milena`;
- преобразование TTS в OGG/Opus через `ffmpeg`, чтобы Telegram показывал
  результат как voice bubble;
- `sounddevice` + `numpy` для локального CLI voice mode;
- image/video analysis через OpenRouter
  `google/gemini-3-flash-preview`.

Параметры задаются в `config/macos.env`:

```env
HERMES_STT_MODEL=base
HERMES_STT_LANGUAGE=ru
HERMES_TTS_VOICE=Milena
HERMES_VISION_MODEL=google/gemini-3-flash-preview
```

Проверенный end-to-end результат на этом Mac mini:

- macOS TTS создал OGG/Opus;
- локальный Whisper распознал созданную русскую речь;
- анализ тестового красного PNG вернул `Красный`;
- анализ тестового синего MP4 вернул `Синий`.

У Mac mini сейчас нет входного аудиоустройства: видны только `Mi Monitor` и
`Динамики Mac mini` с output channels. Это не мешает распознавать Telegram
voice messages, потому что они приходят файлами. Для push-to-talk в локальном
Hermes CLI нужен USB/Bluetooth-микрофон и разрешение macOS на доступ к нему.

Image generation и video generation не включаются автоматически. Это отдельные
backend-плагины с внешними credentials и расходами:

- image: FAL, OpenAI, xAI или Krea;
- video: FAL/xAI/Google Veo provider plugin.

`make check-multimedia` показывает их как `[WARN]`, пока backend не выбран.
