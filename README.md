# hermes-setup

Идемпотентный bash-установщик [Hermes Agent](https://hermes-agent.nousresearch.com) для Linux VPS. Hermes запускается в Docker, а MCP-серверы и Telegram gateway включаются через конфиги.

Для выделенного персонального Mac mini есть отдельный нативный контур:
[`docs/macos-personal-host.md`](docs/macos-personal-host.md). Он использует
Hermes `launchd`, локальный профиль Ollama и безопасную Git-синхронизацию
Obsidian vault, официальный Todoist MCP и scoped filesystem MCP; Linux/Docker
setup при этом не меняется.

## Что делает репозиторий

- Подготавливает Debian/Ubuntu VPS: отдельный пользователь `hermes`, вход по SSH-ключу, UFW, fail2ban, unattended-upgrades.
- Запускает Hermes Agent в Docker-контейнере: `docker exec -it hermes hermes chat`.
- Включает MCP-серверы через `config/mcp.toml`: Playwright и Docker (оба включены по умолчанию). Остальные MCP добавляются вручную.
- Синхронизирует локальные и встроенные Hermes skills через `config/skills.toml`; внешние skill-источники в v1 не скачиваются.
- Монтирует `HERMES_PROJECTS_DIR` (по умолчанию `/home/hermes/projects`) в контейнер как `/home/hermes/projects` — встроенные файловые инструменты Hermes работают с этой директорией.
- Поддерживает Telegram gateway для повседневного доступа, если в `config/gateways.toml` включить `[telegram] enabled = true`.
- Поддерживает стабильный доступ к Google Drive/Docs из Telegram через встроенный Google Workspace skill. Remote `google_drive` MCP можно подключать отдельно, но для Telegram он не основной путь, потому что у него отдельный OAuth.
- Скрипты можно запускать повторно: они проверяют текущее состояние и пропускают уже выполненные шаги.

## Быстрый старт на новом VPS

```bash
# 1. Создай Debian 12 или Ubuntu 26.04 LTS VPS, добавь SSH-ключ и зайди под root.
ssh root@<vps-ip>

# 2. Склонируй репозиторий и подготовь сервер.
#    Скрипт создаст пользователя hermes, поставит Docker, скопирует репозиторий
#    в /home/hermes/hermes-setup, включит SSH hardening и firewall.
git clone https://github.com/RudinMaxim/hermes-setup.git
cd hermes-setup
sudo ./scripts/setup-server.sh

# Если у root нет SSH-ключа, передай ключ явно:
#   HERMES_SSH_KEY="ssh-ed25519 AAAA... you@host" sudo ./scripts/setup-server.sh

# 3. Проверь вход под hermes во ВТОРОМ терминале, не закрывая root-сессию:
#   ssh hermes@<vps-ip>

# 4. Переключись на hermes, заполни секреты и запусти один общий setup.
su - hermes
cd ~/hermes-setup
nano config/.env          # укажи OPENROUTER_API_KEY=..., OPENAI_API_KEY=... или ANTHROPIC_API_KEY=...
# По умолчанию Hermes будет настроен на OpenRouter:
#   HERMES_MODEL_PROVIDER=openrouter
#   HERMES_MODEL=openai/gpt-5.4-mini
# Для этого укажи OPENROUTER_API_KEY=...
# Опционально: поменяй HERMES_PROJECTS_DIR, если в контейнер нужно смонтировать другую host-директорию.
./setup.sh
```

`setup-hermes.sh` сам создаёт `config/.env` из `config/.env.example`, если файла ещё нет. Если LLM-ключ не заполнен, скрипт остановится с понятным сообщением.

Если pull образа `nousresearch/hermes-agent:latest` не удался, `setup-hermes.sh` соберёт локальный образ `hermes-agent:local` из `docker/Dockerfile.hermes` и запишет выбранный `HERMES_IMAGE` в `config/.env`. Fallback-сборка по умолчанию использует `public.ecr.aws/docker/library/ubuntu:24.04`, чтобы не упираться в anonymous rate limit Docker Hub на базовом `ubuntu`. Последующие пересоздания контейнера, включая Telegram gateway, будут использовать тот же образ.

## Интерактивный запуск

Вместо шагов 4-6 можно запустить оркестратор под пользователем `hermes`:

```bash
cd ~/hermes-setup && ./setup.sh
```

В интерактивном терминале он спросит недостающий LLM-ключ, запустит Hermes,
синхронизирует MCP, а затем синхронизирует gateway. Для scripted-запуска используй
`--non-interactive` и заранее заполни `config/.env`.

## MCP

- Из коробки включены два MCP: **Playwright** (браузерная автоматизация) и **Docker** (инспекция контейнеров хоста). Их поднимает `setup-mcp.sh`.
- `setup-mcp.sh` управляет только MCP, которые перечислены в `config/mcp.toml`. MCP-серверы, добавленные в Hermes вручную, не удаляются.
- Остальные интеграции подключаются вручную — проще всего через сам агент Hermes. Общий гайд и примеры: [`docs/mcp/README.md`](docs/mcp/README.md), отдельно [Google Drive](docs/mcp/google_drive.md).
- Docker MCP опасен: mount `/var/run/docker.sock` даёт root-equivalent доступ к хосту. По умолчанию `acknowledge_socket_risk = true`, но MCP остаётся неактивным, пока socket не смонтирован в контейнер. Подробности: [`docs/mcp/docker_mcp.md`](docs/mcp/docker_mcp.md).

## Частые команды

```bash
docker exec -it hermes hermes chat          # открыть CLI Hermes
docker logs --tail=100 hermes               # посмотреть последние логи контейнера
./scripts/setup-hermes.sh                   # синхронизировать config/image/container
./scripts/setup-mcp.sh                      # синхронизировать включённые MCP
./scripts/add-skill.sh my_skill "..."       # создать локальный skill и сразу синхронизировать его
./scripts/setup-skills.sh                   # синхронизировать локальные и встроенные Hermes skills
./scripts/setup-gateway.sh                  # включить или выключить Telegram gateway
./scripts/stabilize-google-workspace.sh     # закрепить Google Drive/Docs для Telegram после CLI OAuth
./scripts/update.sh                         # git pull + пере-синк всего (hermes/mcp/gateway) + обновить MCP-пакеты
```

## Обновление

`./scripts/update.sh` (или `make update`) на VPS под пользователем `hermes`:
подтягивает свежий репозиторий (`git pull --ff-only`), идемпотентно пере-синкает
hermes, MCP и gateway, и обновляет npm-пакеты включённых MCP. Флаги:
`--no-pull` (без git pull), `--no-pkg-update` (без обновления npm-пакетов),
`--pull-image` (скачать новый образ hermes — применяется только при пересоздании
контейнера; на работающем хосте сперва убедись, что volume `hermes_data`
смонтирован в `HERMES_HOME` (`/opt/data`), иначе пересоздание скроет состояние).

## Документация

- [`docs/01-server-setup.md`](docs/01-server-setup.md) — ручные шаги вокруг подготовки VPS: provisioning, DNS, backups.
- [`docs/02-hermes-setup.md`](docs/02-hermes-setup.md) — как заполнить `.env`, запустить Hermes и открыть чат.
- [`docs/mcp/README.md`](docs/mcp/README.md) — как подключать MCP-интеграции вручную через агента, + файл на каждый сервер.
- [`docs/skills/README.md`](docs/skills/README.md) — настройка локальных и встроенных Hermes skills.
- [`docs/gateways/telegram.md`](docs/gateways/telegram.md) — настройка Telegram bot, user ID, privacy mode и стабильный Google Drive/Docs через Workspace skill.
- [`docs/superpowers/specs/2026-05-30-hermes-setup-design.md`](docs/superpowers/specs/2026-05-30-hermes-setup-design.md) — исходный design rationale.

## Тесты

```bash
make test-unit         # быстрые Bats unit-тесты на host
make test-integration  # полные integration-тесты в systemd-enabled Docker sandbox
make test              # оба набора
```

## Структура

```text
setup.sh   тонкий оркестратор для hermes-side шагов
scripts/   setup-server.sh, setup-hermes.sh, setup-mcp.sh, setup-gateway.sh + lib/
config/    .env.example, mcp.toml.example, gateways.toml.example, docker-compose*.yml
skills/    локальные Hermes skills, синхронизируемые через setup-skills.sh
docker/    Dockerfile.hermes для fallback-сборки
docs/      ручные инструкции, MCP и gateway docs
tests/     Bats unit/integration тесты и sandbox Dockerfile
```
