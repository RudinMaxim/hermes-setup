# Hermes Setup Tool — Design

**Status:** approved (brainstorming complete)
**Date:** 2026-05-30
**Owner:** RudinMaksim

## Цель

Воспроизводимая установка Hermes Agent (https://hermes-agent.nousresearch.com) на чистом Linux VPS через Docker, с опциональным набором MCP-серверов. Все автоматизированные шаги идемпотентны (второй запуск любого скрипта даёт только `[SKIP]` и exit 0). То, что нельзя автоматизировать (получение токенов, провижининг VPS), задокументировано отдельными чек-листами.

## Не цели

- Поддержка не-Debian семейств (RHEL/Alpine/macOS). Только Debian/Ubuntu 22.04+.
- Веб-UI и Telegram-gateway в первой версии (только CLI через `docker exec`).
- Hermes-профили (`hermes profile create`) — single-profile установка.
- Кластеризация, бэкап-стратегия, мониторинг.

## Архитектура

### Layout репозитория

```
hermes-setup/
├── README.md                       # quick start
├── docs/
│   ├── 01-server-setup.md          # ручные инструкции (VPS, SSH, DNS)
│   ├── 02-hermes-setup.md          # как заполнить .env, как чатить
│   └── mcp/                        # один файл на MCP: где взять токен
│       ├── github.md
│       ├── playwright.md
│       ├── postgresql.md
│       ├── context7.md
│       ├── memory.md
│       ├── filesystem.md
│       └── docker_mcp.md
├── scripts/
│   ├── setup-server.sh             # подготовка VPS (root)
│   ├── setup-hermes.sh             # Docker + контейнер Hermes (non-root)
│   ├── setup-mcp.sh                # читает mcp.toml, ставит включённые
│   └── lib/
│       ├── log.sh                  # log_ok / log_skip / log_act / log_warn / die
│       ├── checks.sh               # is_pkg_installed, has_user, port_open, …
│       ├── write_file.sh           # write_file_idempotent (atomic + diff-skip)
│       └── toml.sh                 # минимальный awk-парсер mcp.toml
├── config/
│   ├── mcp.toml.example            # шаблон с enabled=false на каждый MCP
│   ├── .env.example                # шаблон секретов с inline-комментариями
│   ├── docker-compose.yml          # сервис hermes + volume + network
│   └── docker-compose.mcp.yml      # дополнительные сервисы для container-MCP
├── docker/
│   └── Dockerfile.hermes           # fallback-сборка если pull не работает
└── tests/
    ├── Dockerfile.ubuntu-systemd   # ubuntu:22.04 + systemd + bats
    ├── run-tests.sh
    ├── helpers/
    │   ├── setup_suite.bash
    │   └── assertions.bash
    ├── unit/
    │   ├── test_log.bats
    │   ├── test_checks.bats
    │   ├── test_toml.bats
    │   └── test_write_file.bats
    └── integration/
        ├── test_server_setup.bats
        ├── test_hermes_setup.bats
        └── test_mcp_setup.bats
```

### Поток установки для пользователя

1. **Руками:** создать VPS у провайдера, добавить SSH-публичный ключ, склонить репо на сервер.
2. `sudo ./scripts/setup-server.sh` — пакеты, юзер `hermes`, Docker, UFW, SSH-hardening.
3. `su - hermes -c './scripts/setup-hermes.sh'` — clone/build образа, запуск контейнера.
4. **Руками:** заполнить `~/hermes-setup/config/.env` минимум одним LLM-ключом (см. `docs/02-hermes-setup.md`).
5. **Руками:** отредактировать `config/mcp.toml`, переключить нужные MCP в `enabled = true` (см. `docs/mcp/<name>.md`).
6. `./scripts/setup-mcp.sh` — поднимает MCP-серверы и регистрирует их в Hermes.

## Принципы реализации

- **Bash strict mode:** `set -euo pipefail; IFS=$'\n\t'` во всех скриптах.
- **Idempotent by state-check:** никаких маркер-файлов. Каждый шаг — функция `ensure_<X>` которая сначала проверяет реальное состояние системы (`id`, `command -v`, `systemctl is-enabled`, `docker ps`, парсинг конфигов), потом действует.
- **Унифицированное логирование:** `[OK]` / `[SKIP]` / `[ACT]` / `[WARN]` / `[ERR]`. Пользователь видит что сделано, что пропущено.
- **Atomic file writes:** `mktemp` → `cmp -s` → `install` (не порвём конфиг если упали посередине).
- **No silent failures:** все `command` без `&>/dev/null` ловят ошибку через `set -e`, явные подавления — только в проверках состояния.

### Шаблон `ensure_*`

```bash
ensure_user_hermes() {
  if id -u hermes &>/dev/null; then
    log_skip "user 'hermes' already exists"
    return 0
  fi
  log_act "creating user 'hermes'"
  useradd -m -s /bin/bash hermes
  log_ok "user 'hermes' created"
}
```

### Таблица проверок состояния

| Ресурс | Проверка |
|---|---|
| Пользователь | `id -u <name>` |
| Член группы | `id -nG <user> \| tr ' ' '\n' \| grep -qx <group>` |
| Пакет (apt) | `dpkg-query -W -f='${Status}' <pkg> 2>/dev/null \| grep -q "ok installed"` |
| Бинарь в PATH | `command -v <cmd>` |
| Файл по содержимому | `cmp -s <new> <existing>` |
| Systemd unit | `systemctl list-unit-files \| grep -q <name>.service` + `is-enabled` + `is-active` |
| UFW rule | `ufw status verbose \| grep -qE '<pattern>'` |
| SSH config key | `grep -qE '^<KEY> <value>' /etc/ssh/sshd_config.d/99-hermes.conf` |
| Docker image | `docker image inspect <img> &>/dev/null` |
| Docker container | `docker ps -a --format '{{.Names}}' \| grep -qx <name>` |
| Docker volume | `docker volume inspect <vol> &>/dev/null` |
| Env var в .env | `grep -qE '^<KEY>=.+' .env` |
| MCP enabled | `lib/toml.sh get_bool <name>.enabled` |
| MCP в Hermes | `docker exec hermes hermes mcp list \| grep -qE '^<name>\s'` |

## Скрипты

### `setup-server.sh` (root)

Запускается от root на чистом Debian/Ubuntu 22.04+.

**Pre-flight guards:**
- `[[ $EUID -eq 0 ]] || die "must run as root"`
- `/etc/os-release` содержит `ID=debian` или `ID_LIKE=*debian*`

**Шаги:**
1. `apt-get update` с кэшем (skip если cache < 60 мин).
2. Базовые пакеты: `ca-certificates curl gnupg ufw fail2ban unattended-upgrades htop git`.
3. Пользователь `hermes` (home, bash). Копия `/root/.ssh/authorized_keys` → `/home/hermes/.ssh/authorized_keys` если у root есть и у hermes ещё нет.
4. Sudoers drop-in `/etc/sudoers.d/hermes` (только `systemctl restart hermes`, `journalctl -u hermes`), валидация `visudo -c`.
5. SSH hardening через `/etc/ssh/sshd_config.d/99-hermes.conf`: `PermitRootLogin no`, `PasswordAuthentication no`, `AllowUsers hermes`. **Safety guard:** перед записью проверяем что `~hermes/.ssh/authorized_keys` существует и непустой — иначе abort (защита от self-lockout). Применяем только после `sshd -t`. `systemctl reload ssh`.
6. UFW: `default deny incoming` / `allow outgoing` / `limit 22/tcp` / `allow 80,443/tcp` / `ufw --force enable`. Каждое правило — через парсинг `ufw status verbose`.
7. fail2ban — `systemctl enable --now`.
8. unattended-upgrades — атомарная запись `/etc/apt/apt.conf.d/20auto-upgrades`.
9. Docker через `get.docker.com` (skip если `command -v docker`). Добавить `hermes` в группу `docker`.
10. `systemctl enable --now docker` (skip если уже).
11. Итог: версии docker, ufw rules, sshd status.

**Что НЕ делает (документировано в `docs/01-server-setup.md`):**
- Provisioning VPS (выбор провайдера/региона)
- Добавление SSH-ключа в провайдер до первого логина
- Настройка DNS/домена
- Бэкап-стратегия

### `setup-hermes.sh` (non-root, от пользователя `hermes`)

**Pre-flight guards:**
- `[[ $EUID -ne 0 ]]` — не root
- `groups | tr ' ' '\n' | grep -qx docker` — иначе подсказка про relogin/`newgrp docker`

**Шаги:**
1. Init configs: `config/mcp.toml.example` → `config/mcp.toml` если нет; `config/.env.example` → `config/.env` если нет.
2. Required-env check: парсинг `.env`, проверка что хотя бы один из `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` непустой. Если нет — печать чек-листа и exit 1.
3. `docker volume create hermes_data` (skip если есть).
4. Image: `docker pull nousresearch/hermes-agent:latest`. **Fallback:** если pull failed — `docker build -f docker/Dockerfile.hermes -t hermes-agent:local .` и переключение compose-файла на локальный тэг. Печатается WARN.
5. `docker network create hermes_net` (skip если есть).
6. `docker compose -f config/docker-compose.yml up -d`. Compose: image, network `hermes_net`, volume `hermes_data:/home/hermes/.hermes`, `env_file: ../config/.env`, `restart: unless-stopped`, healthcheck `hermes --version`.
7. First-run init: `docker exec hermes test -f /home/hermes/.hermes/config.yaml` → skip; иначе `docker exec hermes hermes setup --non-interactive` + установка `redact_secrets: true`.
8. Health gate: ждать до 30с пока `docker exec hermes hermes --version` отвечает 0; иначе abort с `docker logs --tail=50`.
9. Итог.

### `setup-mcp.sh` (non-root)

Config-driven через `config/mcp.toml` — единый источник правды. Что в нём `enabled=true` — установлено и зарегистрировано в Hermes. Что `enabled=false` — удалено из Hermes (если было).

**Шаги:**
1. Pre-check: контейнер `hermes` запущен (`docker ps --filter name=hermes -q`).
2. Парсинг `mcp.toml` → список секций с `enabled=true`.
3. Для каждого включённого MCP:
   - **Required-env check** — все `requires` присутствуют и непустые в `.env`. Если нет — `[ERR] mcp.<name>: missing <KEY>. See docs/mcp/<name>.md`, переход к следующему (не abort всего).
   - **Деплой** по полю `transport`:
     - `stdio` — `docker exec hermes npm install -g <pkg>` если не установлен (`npm list -g --depth=0`).
     - `http` — добавить сервис в `config/docker-compose.mcp.yml`, поднять `docker compose -f config/docker-compose.mcp.yml up -d <service>`, ждать healthcheck.
   - **Регистрация в Hermes:** `hermes mcp add` если в `hermes mcp list` ещё нет.
   - **Smoke-test:** `hermes mcp test <name>` (если поддерживается); иначе парсинг `hermes mcp list` на статус `ok`.
4. Для каждого выключенного MCP, который в `hermes mcp list` присутствует — `hermes mcp remove <name>`.
5. Итог.

**Особый случай — Docker MCP с sock-mount:** если `[docker_mcp] enabled=true`, требуется явное `acknowledge_socket_risk = true` в той же секции toml. Иначе печатается WARN и MCP пропускается (security guard: монтирование `/var/run/docker.sock` равноценно root на хосте).

## Конфигурация

### `mcp.toml.example`

Developer-стек из `mcp.md` плюс Filesystem и Memory:

```toml
[filesystem]
enabled = false
description = "локальный FS (доступ к ~/projects в контейнере)"
transport = "stdio"
package = "@modelcontextprotocol/server-filesystem"
requires = []
mount = "/home/hermes/projects"

[github]
enabled = false
description = "репозитории, PR, issues"
transport = "stdio"
package = "@modelcontextprotocol/server-github"
requires = ["GITHUB_TOKEN"]

[context7]
enabled = false
description = "актуальная документация библиотек"
transport = "stdio"
package = "@upstash/context7-mcp"
requires = []  # без ключа — anonymous tier

[memory]
enabled = false
description = "долгосрочная память агента (SQLite в volume)"
transport = "stdio"
package = "@modelcontextprotocol/server-memory"
requires = []

[playwright]
enabled = false
description = "браузер для E2E / парсинга"
transport = "http"
image = "mcr.microsoft.com/playwright/mcp:latest"
port = 9001
requires = []

[postgres]
enabled = false
description = "выполнение SQL, анализ схемы"
transport = "stdio"
package = "@modelcontextprotocol/server-postgres"
requires = ["POSTGRES_URL"]

[docker_mcp]
enabled = false
description = "просмотр контейнеров и логов на хосте"
transport = "stdio"
package = "@modelcontextprotocol/server-docker"
requires = []
acknowledge_socket_risk = false   # ОБЯЗАТЕЛЬНО true, иначе MCP пропускается
```

### `.env.example`

```ini
# ── LLM provider (хотя бы один обязателен) ──────────
# https://platform.openai.com/api-keys
OPENAI_API_KEY=
# https://console.anthropic.com/settings/keys
ANTHROPIC_API_KEY=

# ── MCP secrets (заполнить если включаешь соответствующий MCP) ──
# Где взять: docs/mcp/github.md
GITHUB_TOKEN=
# Где взять: docs/mcp/context7.md (опционально)
CONTEXT7_API_KEY=
# Где взять: docs/mcp/postgresql.md
POSTGRES_URL=
```

### `docker-compose.yml`

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    env_file: ../config/.env
    volumes:
      - hermes_data:/home/hermes/.hermes
    networks: [hermes_net]
    healthcheck:
      test: ["CMD", "hermes", "--version"]
      interval: 30s
      timeout: 5s
      retries: 3

volumes:
  hermes_data:
networks:
  hermes_net:
    name: hermes_net
```

## Документация по MCP (формат)

Каждый `docs/mcp/<name>.md` следует одному шаблону:

```markdown
# <Name> MCP

## Что нужно вручную
1. Шаг 1 (с конкретным URL)
2. Шаг 2 …
N. В `config/.env` установить: `<KEY>=<value>`
N+1. В `config/mcp.toml`: `[<name>] enabled = true`
N+2. Запустить: `./scripts/setup-mcp.sh`

## Что делает скрипт
- (список действий)

## Troubleshooting
- (типовые ошибки и проверки)
```

## Тестирование

### Bats + Docker-sandbox

**Sandbox-образ** `tests/Dockerfile.ubuntu-systemd`:
```dockerfile
FROM jrei/systemd-ubuntu:22.04
RUN apt-get update && apt-get install -y bats curl sudo iproute2 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
ENTRYPOINT ["/lib/systemd/systemd"]
```

Запуск: `docker run --rm --privileged -v $PWD:/repo -v /sys/fs/cgroup:/sys/fs/cgroup:rw hermes-test`. systemd, sshd, ufw работают.

### Unit-тесты

Чистые функции из `scripts/lib/*`. Запускаются на хост-bash без Docker. Покрытие:
- `log.sh` — корректные префиксы и exit-коды.
- `checks.sh` — все `is_*`/`has_*` функции через моки команд.
- `toml.sh` — парсинг секций, ключей, булевых, списков; edge-кейсы (комментарии, пробелы, кавычки).
- `write_file.sh` — atomic write + diff-skip.

### Integration-тесты

Каждый проверяет **idempotency-инвариант**:
```bash
@test "setup-server.sh is idempotent" {
  run scripts/setup-server.sh
  assert_success

  run scripts/setup-server.sh
  assert_success
  refute_output --regexp '^\[(ACT|OK)\]'
  assert_output --regexp '^\[SKIP\]'
}
```

Помимо этого — функциональные проверки: что юзер создан, ufw активен, docker запущен, контейнер hermes в `running`, MCP зарегистрирован в `hermes mcp list`.

### Признанные ограничения тестов

Документировано в `tests/README.md`:
- UFW в Docker добавляет правила в свой netns, не блокирует трафик хоста — проверяем парсинг `ufw status`, не реальную фильтрацию.
- Docker-in-Docker через `docker:dind` sidecar — pull/build идут туда, не на хост.
- fail2ban запускается, но bans не применяются — `systemctl is-active` достаточно.
- Реальный pull `nousresearch/hermes-agent` зависит от того что образ существует — тест мокает `docker pull` через PATH-override, фоллбэк-сборка проверяется отдельным тестом.

### Не покрыто тестами (manual smoke-check)

- Реальная установка на реальный VPS у провайдера — финальная проверка после первой версии.
- Получение настоящих токенов GitHub PAT, Telegram BotFather, и т.д.
- Реальный успешный MCP-вызов с валидными credentials — мы проверяем только что MCP зарегистрирован и `hermes mcp test` не возвращает `not configured`.

## Открытые вопросы (для v2)

- Telegram-gateway (требует `TELEGRAM_BOT_TOKEN`, allowed_users, опциональный webhook через nginx + LetsEncrypt).
- WebUI (если Hermes её поддерживает — нужен reverse-proxy и TLS).
- Бэкап `~/.hermes` volume.
- Auto-update контейнера (Watchtower или systemd timer + `docker compose pull && up -d`).
- Hermes-профили (несколько личностей в одной установке).
