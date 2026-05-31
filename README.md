# hermes-setup

Идемпотентный bash-установщик [Hermes Agent](https://hermes-agent.nousresearch.com) для Linux VPS. Hermes запускается в Docker, а MCP-серверы и Telegram gateway включаются через конфиги.

## Что делает репозиторий

- Подготавливает Debian/Ubuntu VPS: отдельный пользователь `hermes`, вход по SSH-ключу, UFW, fail2ban, unattended-upgrades.
- Запускает Hermes Agent в Docker-контейнере: `docker exec -it hermes hermes chat`.
- Позволяет включать MCP-серверы через `config/mcp.toml`: Filesystem, GitHub, Context7, Memory, Playwright, Postgres, Docker.
- Монтирует директорию для Filesystem MCP через `HERMES_PROJECTS_DIR` (по умолчанию `/home/hermes/projects`) в контейнер как `/home/hermes/projects`.
- Поддерживает Telegram gateway для повседневного доступа, если в `config/gateways.toml` включить `[telegram] enabled = true`.
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

# 4. Переключись на hermes, заполни LLM-ключ и запусти Hermes.
su - hermes
cd ~/hermes-setup
nano config/.env          # укажи OPENROUTER_API_KEY=..., OPENAI_API_KEY=... или ANTHROPIC_API_KEY=...
# По умолчанию Hermes будет настроен на OpenRouter:
#   HERMES_MODEL_PROVIDER=openrouter
#   HERMES_MODEL=openai/gpt-5.4-mini
# Для этого укажи OPENROUTER_API_KEY=...
# Опционально: поменяй HERMES_PROJECTS_DIR, если Filesystem MCP должен открыть другую host-директорию.
./scripts/setup-hermes.sh

# 5. Опционально: включи MCP-серверы.
nano config/mcp.toml      # поставь enabled = true для нужных MCP
./scripts/setup-mcp.sh

# 6. Опционально: включи Telegram gateway.
nano config/gateways.toml # поставь [telegram] enabled = true
./scripts/setup-gateway.sh
```

`setup-hermes.sh` сам создаёт `config/.env` из `config/.env.example`, если файла ещё нет. Если LLM-ключ не заполнен, скрипт остановится с понятным сообщением.

Если pull образа `nousresearch/hermes-agent:latest` не удался, `setup-hermes.sh` соберёт локальный образ `hermes-agent:local` из `docker/Dockerfile.hermes` и запишет выбранный `HERMES_IMAGE` в `config/.env`. Fallback-сборка по умолчанию использует `public.ecr.aws/docker/library/ubuntu:26.04`, чтобы не упираться в anonymous rate limit Docker Hub на базовом `ubuntu`. Последующие пересоздания контейнера, включая Telegram gateway, будут использовать тот же образ.

## Интерактивный запуск

Вместо шагов 4-6 можно запустить оркестратор под пользователем `hermes`:

```bash
cd ~/hermes-setup && ./setup.sh
```

В интерактивном терминале он спросит LLM-ключ, запустит Hermes, а затем предложит настроить Telegram gateway и MCP. Для scripted-запуска используй `--non-interactive` и заранее заполни `config/.env`.

## MCP

- `setup-mcp.sh` управляет только MCP, которые перечислены в `config/mcp.toml`. MCP-серверы, добавленные в Hermes вручную, не удаляются.
- Для Filesystem MCP оставь `mount = "/home/hermes/projects"` в `config/mcp.toml`. Host-директория настраивается через `HERMES_PROJECTS_DIR` в `config/.env`.
- Docker MCP опасен: mount `/var/run/docker.sock` даёт root-equivalent доступ к хосту. Скрипт требует `acknowledge_socket_risk = true` и проверяет, что socket уже смонтирован в контейнер. Подробности: [`docs/mcp/docker_mcp.md`](docs/mcp/docker_mcp.md).

## Частые команды

```bash
docker exec -it hermes hermes chat          # открыть CLI Hermes
docker logs --tail=100 hermes               # посмотреть последние логи контейнера
./scripts/setup-hermes.sh                   # синхронизировать config/image/container
./scripts/setup-mcp.sh                      # синхронизировать включённые MCP
./scripts/setup-gateway.sh                  # включить или выключить Telegram gateway
```

## Документация

- [`docs/01-server-setup.md`](docs/01-server-setup.md) — ручные шаги вокруг подготовки VPS: provisioning, DNS, backups.
- [`docs/02-hermes-setup.md`](docs/02-hermes-setup.md) — как заполнить `.env`, запустить Hermes и открыть чат.
- [`docs/mcp/`](docs/mcp/) — отдельный файл на каждый MCP-сервер.
- [`docs/gateways/telegram.md`](docs/gateways/telegram.md) — настройка Telegram bot, user ID и privacy mode.
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
docker/    Dockerfile.hermes для fallback-сборки
docs/      ручные инструкции, MCP и gateway docs
tests/     Bats unit/integration тесты и sandbox Dockerfile
```
