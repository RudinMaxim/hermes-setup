# MCP-интеграции

Этот репозиторий держит **минимальный** набор MCP «из коробки», а остальные
интеграции подключаются вручную — проще всего через сам агент Hermes.

## Из коробки

В `config/mcp.toml` по умолчанию включены два сервера, их поднимает
`setup-mcp.sh` (вызывается из `./setup.sh`):

| MCP | Что делает | Замечание |
|---|---|---|
| [`playwright`](playwright.md) | Браузерная автоматизация / скрапинг | Поднимается автоматически |
| [`docker_mcp`](docker_mcp.md) | Инспекция контейнеров и логов хоста | ⚠️ Активен только после ручного монтирования `/var/run/docker.sock` |

`setup-mcp.sh` управляет **только** секциями из `config/mcp.toml`. Всё, что ты
добавишь в Hermes вручную, скрипт не трогает и не удаляет.

## Как добавить интеграцию вручную через агента

Hermes сам умеет редактировать свой `config.yaml`. Самый простой путь —
попросить его об этом в чате:

```bash
docker exec -it hermes hermes chat
```

Пример запроса агенту:

> Добавь MCP-сервер `github`: stdio-транспорт, команда `npx -y
> @modelcontextprotocol/server-github`, переменная окружения `GITHUB_TOKEN`.
> Затем проверь конфиг, перезапусти Hermes при необходимости и проверь
> подключение.

Агент впишет сервер в `$HERMES_HOME/config.yaml` (на текущем образе это
`/opt/data/config.yaml`). В текущей версии Hermes команды `config reload` нет:
после ручной правки используй `hermes config check` и перезапуск контейнера.

## Как добавить вручную через config.yaml

Если хочешь сделать это сам, формат записи такой:

```yaml
mcp_servers:
  github:
    enabled: true
    command: npx
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_TOKEN: ${GITHUB_TOKEN}
  some_http_mcp:
    enabled: true
    url: https://example.com/mcp
```

```bash
# отредактировать конфиг внутри контейнера, если в образе есть редактор
docker exec -it hermes bash -lc 'vi "$HERMES_HOME/config.yaml"'
# секреты держим в config/.env (он монтируется в контейнер как env_file)
docker exec -u root hermes chown hermes:hermes /opt/data/config.yaml
docker exec -u root hermes chmod 600 /opt/data/config.yaml
docker exec hermes hermes config check
docker restart hermes
docker exec hermes hermes mcp test github
```

stdio-серверам на npm обычно нужна установка пакета:
```bash
docker exec hermes npm install -g @modelcontextprotocol/server-github
```

## Доступные инструкции

- [`google_drive.md`](google_drive.md) — Google Drive/Docs. Для Telegram используй встроенный Google Workspace skill + `./scripts/stabilize-google-workspace.sh`; remote `google_drive` MCP описан отдельно и требует свой OAuth.
- [`playwright.md`](playwright.md) — браузерная автоматизация.
- [`docker_mcp.md`](docker_mcp.md) — инспекция Docker на хосте.
