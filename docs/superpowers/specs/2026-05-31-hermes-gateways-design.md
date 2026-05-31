# Hermes Gateways — Design

**Status:** approved (brainstorming complete)
**Date:** 2026-05-31
**Owner:** RudinMaksim
**Builds on:** `2026-05-30-hermes-setup-design.md`

## Цель

Дать Hermes ежедневный доступ через gateway'и, config-driven (как `mcp.toml`).
Фаза 1 — **Telegram**: токен в `.env`, allowlist по user ID, валидация токена
через Telegram getMe, запуск `hermes gateway run` как PID 1 контейнера.
Фаза 2 (deferred, спроектирована но НЕ реализуется сейчас) — **WebUI** через
`hermes dashboard` + Caddy (опциональный домен + Let's Encrypt HTTPS).

Параллельно вводится слой **интерактивной инициализации**: при запуске в TTY
скрипты сами спрашивают недостающие секреты (LLM-ключ, Telegram-токен) и пишут
их в `.env`; тонкий `setup.sh` оркеструет hermes-сторону (hermes → gateway →
mcp). Неинтерактивный путь сохраняется без изменений (как сейчас — `die` с
инструкцией), идемпотентность не нарушается (промпт срабатывает только когда
значение отсутствует).

## Не цели

- WebUI в этой итерации (только эскиз в разделе Phase 2).
- Discord/Slack/прочие gateway'и (паттерн расширяемый, но вне scope).
- Изменение privacy mode бота из скрипта — это настройка на стороне Telegram
  (@BotFather), документируется как ручной шаг.
- Валидация что конкретные user ID реальны — проверяется только формат (числа).

## Установленные факты (Hermes v0.15.1, из docs)

- `hermes config` subcommands: `show | edit | set <k> <v> | path | env-path`.
  **`get` НЕ существует** (отсюда прошлый баг redact_secrets, уже исправлен).
- `hermes gateway run` — gateway в foreground (подходит для PID 1).
- `hermes gateway install | start | status | restart` — для systemd-сервиса
  (мы используем Docker, поэтому `run` как команда контейнера).
- Telegram: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS=id1,id2`.
  Default-deny: «gateway denies all users not in allowlist or paired via DM».
- DM-pairing: `hermes pairing approve|list|revoke` (не используем в фазе 1,
  выбрали статичный allowlist).
- WebUI: `hermes dashboard [--port PORT] [--host HOST]`.

## Архитектура

### Конфиг-модель

Новый `config/gateways.toml` — единый источник правды. Токены в `.env`.

```toml
# config/gateways.toml.example
[telegram]
enabled = false
requires = ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS"]

[webui]
# Phase 2 — not implemented yet. setup-gateway.sh warns and ignores this.
enabled = false
domain  = ""    # empty → IP/tunnel access; set → Caddy + Let's Encrypt HTTPS
requires = []
```

### Запуск gateway в контейнере

`hermes gateway run` — foreground, ставится как PID 1 через **override-compose**
`config/docker-compose.gateway.yml`, который мерджится поверх базового только
когда messaging-gateway включён:

```
docker compose -f config/docker-compose.yml -f config/docker-compose.gateway.yml up -d
```

- gateway выключен → контейнер с дефолтной командой образа (CLI/exec/MCP работают).
- gateway включён → PID 1 = `hermes gateway run`; `docker exec hermes hermes chat`
  по-прежнему работает (exec — отдельный процесс, не PID 1).

`docker-compose.gateway.yml`:
```yaml
# Override applied by setup-gateway.sh when a messaging gateway is enabled.
# Replaces the container command with the foreground gateway runner.
services:
  hermes:
    command: ["hermes", "gateway", "run"]
```

`TELEGRAM_BOT_TOKEN` / `TELEGRAM_ALLOWED_USERS` уже прокинуты в контейнер через
`env_file: ./.env` в базовом compose — `hermes gateway run` читает их из env.

### Скрипт `scripts/setup-gateway.sh` (от пользователя hermes)

```bash
main() {
  require_files            # gateways.toml + .env
  require_hermes_running

  if gateway_enabled telegram; then
    ensure_telegram        # validate → apply override → health
  else
    ensure_telegram_off    # rollback to idle if it was on
  fi

  if gateway_enabled webui; then
    log_warn "webui gateway is Phase 2 — not implemented yet, ignoring [webui] enabled=true"
  fi

  log_ok "gateway sync complete"
}
```

State-check «gateway уже запущен» — по реальной команде PID 1:
```bash
telegram_gateway_active() {
  docker inspect -f '{{join .Config.Cmd " "}}' hermes 2>/dev/null \
    | grep -q 'gateway run'
}
```

`ensure_telegram`:
```bash
ensure_telegram() {
  validate_telegram                      # die on bad token/allowlist
  if telegram_gateway_active; then
    log_skip "telegram gateway already running (PID1 = hermes gateway run)"
    return 0
  fi
  log_act "starting telegram gateway (recreating container with gateway command)"
  docker compose -f "$CONFIG_DIR/docker-compose.yml" \
                 -f "$CONFIG_DIR/docker-compose.gateway.yml" up -d >/dev/null
  wait_for_gateway
  log_ok "telegram gateway is up — message your bot to test"
}
```

`ensure_telegram_off` (откат — toml как единый источник правды):
```bash
ensure_telegram_off() {
  if ! telegram_gateway_active; then
    log_skip "telegram gateway not running"
    return 0
  fi
  log_act "disabling telegram gateway (recreating container without gateway command)"
  docker compose -f "$CONFIG_DIR/docker-compose.yml" up -d --force-recreate >/dev/null
  log_ok "telegram gateway stopped; container back to idle/CLI mode"
}
```

`wait_for_gateway` — до 30с ждёт признак живости (`hermes gateway status`
возвращает 0, либо в `docker logs hermes` появляется строка о старте gateway);
иначе `docker logs --tail=50 hermes` и `die`.

## Интерактивная инициализация

Цель — не заставлять пользователя руками править `.env` (это шло вразрез с
«автоматизируй инициализацию»). Форма: **промпты в самих скриптах + тонкий
`setup.sh`** (не монолитный wizard, чтобы не дублировать cross-user проблему
root vs hermes и сохранить тестируемость отдельных скриптов).

### Принципы

- **TTY-gating.** Промпт только если `[[ -t 0 && -t 1 ]]` И не задан
  `HERMES_NONINTERACTIVE=1` (и нет флага `--non-interactive`). Иначе —
  текущее поведение: `die` с инструкцией. CI/sandbox-тесты идут неинтерактивным
  путём.
- **Идемпотентность не ломается.** Промпт срабатывает ТОЛЬКО когда значение
  отсутствует. Значение уже в `.env` → промпта нет → `[SKIP]`. Второй прогон
  (и `assert_idempotent`, который всегда неинтерактивен) → только `[SKIP]`.
- **Секреты не светятся.** Ввод токенов через `read -rs` (без эха). В логах —
  только маска вида `token saved (N chars)`, никогда само значение. Запись в
  `.env` с правами `0600` (уже выставляются в `ensure_configs`).

### Новый `lib/prompt.sh`

Чистые/тестируемые примитивы:

```bash
# set_env_value FILE KEY VALUE — идемпотентный upsert строки KEY=VALUE.
# Если KEY уже равен VALUE — ничего не пишет (return 1 = "no change"),
# иначе заменяет существующую строку или дописывает в конец (return 0).
# awk-based, без regex-инъекции (KEY и VALUE — литералы).
set_env_value() { ... }

is_interactive() { [[ -t 0 && -t 1 && "${HERMES_NONINTERACTIVE:-}" != 1 ]]; }

prompt_value()  { local p="$1"; local out; read -r  -p "$p: " out; printf '%s' "$out"; }
prompt_secret() { local p="$1"; local out; read -rs -p "$p: " out; echo >&2; printf '%s' "$out"; }
confirm()       { local p="$1"; local a; read -r -p "$p [y/N]: " a; [[ "$a" =~ ^[Yy] ]]; }
```

`set_env_value` юнит-тестируется (новый ключ дописан; существующий заменён;
идентичное значение → не тронуто; значения со спецсимволами `=`/`&`/`/` целы).

### Изменение в `setup-hermes.sh` → `ensure_llm_key`

Сейчас при отсутствии ключа — `die`. Новое поведение:

```bash
ensure_llm_key() {
  if env_var_set_in_file "$ENVFILE" OPENAI_API_KEY \
     || env_var_set_in_file "$ENVFILE" ANTHROPIC_API_KEY; then
    log_ok "LLM API key present in .env"; return 0
  fi
  if is_interactive; then
    local provider key var
    provider=$(prompt_value "LLM provider (openai/anthropic)")
    case "$provider" in
      anthropic) var=ANTHROPIC_API_KEY ;;
      *)         var=OPENAI_API_KEY ;;
    esac
    key=$(prompt_secret "$var")
    [[ -n "$key" ]] || die "empty key"
    set_env_value "$ENVFILE" "$var" "$key" >/dev/null
    log_ok "$var saved to .env (${#key} chars)"
    return 0
  fi
  die "no LLM API key configured — set OPENAI_API_KEY or ANTHROPIC_API_KEY in $ENVFILE (see docs/02-hermes-setup.md)"
}
```

### Изменение в `setup-gateway.sh` → `validate_telegram`

Перед валидацией: если токен/allowlist отсутствуют и `is_interactive` — спросить
и записать в `.env`, затем валидировать как обычно. Если неинтерактивно —
текущий `die`. Промпт для allowlist поясняет, что это числовые user ID через
запятую (как узнать ID — ссылка на `docs/gateways/telegram.md`).

### Тонкий `setup.sh` (оркестратор hermes-стороны)

Запускается из корня репо пользователем hermes. **Не** включает server-шаг
(он root и одноразовый) — если запущен от root или сервер не подготовлен,
печатает `[WARN]` со ссылкой на `setup-server.sh` и продолжает hermes-часть.

```bash
main() {
  [[ $EUID -ne 0 ]] || log_warn "setup.sh is the hermes-side orchestrator; run setup-server.sh as root separately"
  "$SCRIPT_DIR/scripts/setup-hermes.sh" "$@"        # LLM-ключ спросится тут
  if is_interactive && confirm "Configure a messaging gateway (Telegram) now?"; then
    "$SCRIPT_DIR/scripts/setup-gateway.sh" "$@"
  fi
  if is_interactive && confirm "Sync MCP servers from mcp.toml now?"; then
    "$SCRIPT_DIR/scripts/setup-mcp.sh" "$@"
  fi
  log_ok "setup complete"
}
```

Флаг `--non-interactive` (и `HERMES_NONINTERACTIVE=1`) пробрасывается в дочерние
скрипты; в этом режиме `setup.sh` не задаёт вопросов и просто прогоняет
hermes-шаг (gateway/mcp — только если их `*.toml` уже сконфигурён `enabled`).
`setup.sh` — тонкая обёртка: вся идемпотентная логика в дочерних скриптах, сам
он лишь последовательность + да/нет.

## Валидация Telegram

### Чистые функции (юнит-тестируемые)

`lib/checks.sh` (общие):
```bash
# is_numeric_csv "123,456" -> 0 ; "123,abc" / "" / "12," -> 1
is_numeric_csv() {
  local v="$1"
  [[ -n "$v" ]] || return 1
  [[ "$v" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

# read_env_value FILE KEY -> prints the value (comments/whitespace stripped),
# exit 1 if absent. Complements env_var_set_in_file (which is boolean only).
read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -v k="$key" '
    { sub(/^[[:space:]]+/, ""); if ($0 ~ /^#/) next
      eq = index($0, "="); if (eq == 0) next
      lhs = substr($0, 1, eq-1); sub(/[[:space:]]+$/, "", lhs)
      if (lhs != k) next
      rhs = substr($0, eq+1); sub(/^[[:space:]]+/, "", rhs); sub(/[[:space:]]+$/, "", rhs)
      print rhs; found=1; exit }
    END { exit (found ? 0 : 1) }
  ' "$file"
}
```

`lib/telegram.sh` (Telegram-специфично):
```bash
# telegram_getme_username '<json>' -> prints username, exit 0 if "ok":true
telegram_getme_username() {
  local json="$1"
  grep -q '"ok":[[:space:]]*true' <<<"$json" || return 1
  sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<<"$json"
}
```

### Сетевой вызов (в setup-gateway.sh, не юнит-тестируется)

```bash
validate_telegram() {
  local token allow resp uname count
  token=$(read_env_value "$ENVFILE" TELEGRAM_BOT_TOKEN) \
    || die "TELEGRAM_BOT_TOKEN missing in .env — see docs/gateways/telegram.md"
  allow=$(read_env_value "$ENVFILE" TELEGRAM_ALLOWED_USERS) || allow=""

  is_numeric_csv "$allow" \
    || die "TELEGRAM_ALLOWED_USERS must be comma-separated numeric IDs (got: '$allow') — see docs/gateways/telegram.md"

  # getMe is read-only — logged as a state check ([SKIP]/[OK]), never [ACT],
  # so the idempotency invariant (2nd run = only [SKIP]) holds.
  resp=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getMe") \
    || die "Telegram getMe request failed — token invalid or no network"
  uname=$(telegram_getme_username "$resp") \
    || die "Telegram rejected the token (ok != true) — check TELEGRAM_BOT_TOKEN"
  count=$(tr ',' '\n' <<<"$allow" | grep -c .)
  log_skip "telegram token valid: bot @${uname}, allowlist has ${count} user(s)"
}
```

**Privacy mode** (бот в группах): по умолчанию бот видит только команды (`/cmd`).
Чтобы читал все сообщения группы — @BotFather → `/setprivacy` → Disable. Из
скрипта недоступно → ручной шаг в `docs/gateways/telegram.md`. Allowlist по
user ID фильтрует отправителя одинаково в личке и в группах.

## Идемпотентность

Инвариант проекта сохраняется: второй прогон при `enabled=true` →
- `validate_telegram` логирует getMe как `[SKIP]` (read-only),
- `telegram_gateway_active` → true → `[SKIP]`.
Никаких `[ACT]`/`[OK]` → проходит `assert_idempotent`.

Цикл disable: `enabled=true` (up) → `enabled=false` (`[ACT] disabling` →
recreate без override) → повторный disabled-прогон `[SKIP]`.

## Файлы

```
setup.sh                              # тонкий оркестратор hermes-стороны
config/gateways.toml.example          # [telegram] + [webui] заглушка
config/docker-compose.gateway.yml     # override: command = hermes gateway run
scripts/setup-gateway.sh              # новый скрипт (+интерактивный ввод токена)
scripts/lib/checks.sh                 # +is_numeric_csv, +read_env_value
scripts/lib/telegram.sh               # +telegram_getme_username
scripts/lib/prompt.sh                 # +set_env_value, is_interactive, prompt_*
scripts/setup-hermes.sh               # init gateways.toml->; ensure_llm_key интерактивен; --non-interactive
scripts/setup-mcp.sh                  # принять флаг --non-interactive (no-op для совместимости setup.sh)
docs/gateways/telegram.md             # ручные шаги (BotFather, privacy, user ID)
docs/02-hermes-setup.md               # ссылка на gateways + интерактивный режим
README.md                             # шаг: ./setup.sh (интерактив) + опциональные gateways
tests/unit/test_telegram.bats         # getMe-парсер + is_numeric_csv + read_env_value
tests/unit/test_prompt.bats           # set_env_value (upsert/no-change/спецсимволы), is_interactive
tests/integration/test_gateway_setup.bats  # stub docker+curl: up / bad token / rollback / idempotency
```

`telegram.sh` отдельным файлом: getMe-парсер специфичен для Telegram;
`is_numeric_csv`/`read_env_value` общие → в `checks.sh`.

## Тестирование

### Unit (host, fast)
- `telegram_getme_username`: `{"ok":true,...,"username":"my_bot"}`→`my_bot`;
  `{"ok":false}`→exit1; мусор→exit1.
- `is_numeric_csv`: `123,456`→0; `123`→0; `12,ab`→1; ``→1; `12,`→1.
- `read_env_value`: достаёт значение; игнорит `# comment`; отсутствует→exit1.
- `set_env_value`: новый ключ дописан; существующий заменён; идентичное значение
  → файл не изменён (return 1); значения с `=`/`&`/`/` сохранены дословно.
- `is_interactive`: при `HERMES_NONINTERACTIVE=1` → false (без TTY-зависимости).

### Integration (sandbox, stub docker + curl)
- enabled=true + getMe-stub ok:true → контейнер с `gateway run`
  (`docker inspect ... Cmd`), `[OK] telegram gateway is up`.
- getMe-stub ok:false → `die`, exit≠0.
- нечисловой `TELEGRAM_ALLOWED_USERS` → `die` (getMe не вызывается).
- idempotency: два прогона enabled=true → второй только `[SKIP]`.
- rollback: up → enabled=false → `[ACT] disabling` → Cmd без `gateway run`;
  третий disabled-прогон → `[SKIP]`.

curl стабится через PATH-override (как docker в существующих тестах). Все
integration-прогоны идут с `HERMES_NONINTERACTIVE=1` (без TTY в sandbox), поэтому
ветка `die`-без-ключа покрывается: `setup-hermes.sh` без LLM-ключа и без TTY →
`die`, exit≠0 (подтверждает, что промпт не блокирует неинтерактивный путь).

### Признанные ограничения
- Реальный приём сообщений ботом не тестируется (нужен живой Telegram) —
  manual smoke на VPS.
- `hermes gateway run` как PID 1 и поведение `hermes gateway status`
  подтверждаются на реальном VPS (структура CLI образа).

## Phase 2 — WebUI (deferred, не реализуется сейчас)

Эскиз для будущего спека:
- `config/docker-compose.mcp.yml`-стиль: сервис `hermes-dashboard`
  (`hermes dashboard --host 0.0.0.0 --port 8080`), общий volume `hermes_data`.
- Если `[webui] domain` задан → сервис `caddy` (профиль `webui`):
  reverse-proxy с auto-TLS (Let's Encrypt по домену) + basic-auth, проксирует
  на `hermes-dashboard:8080`. DNS A-запись `domain → IP` — ручной prerequisite.
- Если `domain` пуст → dashboard слушает только localhost, доступ через
  `ssh -L 8080:localhost:8080` (без открытых портов, без TLS-проблем).
- `setup-gateway.sh` фазы 1 печатает `[WARN]` при `[webui] enabled=true`.

## Открытые вопросы (на момент реализации, решаются на VPS)
- Точная строка-признак старта gateway в логах для `wait_for_gateway`
  (fallback: `hermes gateway status` exit code).
- Нужен ли Hermes config-ключ для «включения» telegram помимо наличия
  env-vars, или присутствия `TELEGRAM_BOT_TOKEN` + `hermes gateway run`
  достаточно (docs предполагают второе).
