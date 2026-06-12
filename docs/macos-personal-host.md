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
launchctl print "gui/$(id -u)/ai.hermes.obsidian-sync"
tail -n 100 ~/Library/Logs/hermes/obsidian-sync.log
```

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

Текущий блокер на Mac mini: найденный Desktop OAuth client
`216823113834-1h1np9p22e5i96j8q3hh43osqv1enjv8.apps.googleusercontent.com`
удалён в Google Cloud и возвращает `401 deleted_client`. Для продолжения нужен
новый OAuth Client ID типа **Desktop app** и новый JSON. Старую ссылку
авторизации повторно использовать нельзя.

## Todoist MCP

Используется официальный Doist endpoint:

```text
https://ai.todoist.net/mcp
```

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
