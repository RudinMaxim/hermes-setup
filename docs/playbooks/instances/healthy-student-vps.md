# Установка: сервер healthy-student (80.78.242.246)

Эталон для [плейбука](../shared-host-user-install.md). Секретов здесь нет: ключи лежат в
`~/.hermes/.env` на сервере, пароль интерфейса — в менеджере паролей владельца.

| Что | Значение |
|---|---|
| Сервер | 80.78.242.246, Ubuntu 26.04, 2 CPU / 3.8 ГБ RAM / 2 ГБ swap, MTU 1450 |
| Рядом на сервере | сайт healthy-student.ru (Docker-проект `healthy-student-prod`, Caddy в контейнере `web`) |
| Health-check прода | `curl -s https://healthy-student.ru/api/v1/health` → `{"status":"ok"}` |
| Пользователь | `hermes` (uid 1001), без sudo и Docker, linger включён |
| SSH | алиас `hermes-vps`, ключ `~/.ssh/hermes_vps` у исполнителя (у каждого свой — добавить через root, шаг 3) |
| Hermes | 0.22.5, `~/.hermes`, установлен 2026-11-01 с обходом `nodejs.org` |
| Модель | основной: Timeweb `https://api.timeweb.ai/v1`, `anthropic/claude-haiku-5-5` (с 08.11.2026; ~2,1 ₽ за сценарий против 21 ₽ на `gemini-3.5-flash`), ключ `TIMEWEB_API_KEY` |
| Запасной провайдер | `fallback_providers`: Timeweb `gemini/gemini-3.5-flash-lite`, затем reg.cloud `https://ai.reg.cloud/v1` `glm-5.3-flash`, ключ `REGCLOUD_API_KEY`; бэкап до смены `config.yaml.bak-20261108-model` |
| Сжатие и бюджет | `compression.threshold_tokens 48000`, `protect_last_n 8`, `min_tail_user_messages 2`, `proactive_prune_tokens 20000`; `tool_budget.mcp_result_size_chars 15000` |
| Чистка (08.11.2026) | `skills.disabled` — 48 навыков (осталось 13); наборы VK/cron/CLI 12/8/14; бэкап `config.yaml.bak-20261108` |
| Интерфейс | сервис `hermes-dashboard` (`systemctl --user`), слушает `172.17.0.1:9119` |
| Домен | https://hermes.turni.ru, логин `maksim` |
| Прокси | Caddyfile в репо `cmmb-prototyping-lab/healthy-student`, PR #11 (merged 2026-11-01) |
| ufw | `172.17.0.1 9119/tcp ALLOW 172.18.0.0/16` (добавлено 2026-11-01) |
| Туннель | `ssh -N -L 9119:172.17.0.1:9119 hermes-vps` → http://localhost:9119 |
| Gateway | сервис `hermes-gateway` (`systemctl --user`), с 2026-11-01 |
| Подтверждения | `approvals.mode: manual`; Todoist `trust: untrusted` (проверено: запись без подтверждения блокируется); правила в `~/.hermes/SOUL.md` (rules v3 — +формат под канал, 02.11.2026); в VK отключён `code_execution`, `approvals.deny` на вставки кода |
| Todoist | официальный MCP `ai.todoist.net/mcp`, токен `MCP_TODOIST_API_KEY`, 26 инструментов (21 исключён в `tools.exclude`, 08.11.2026), `timeout: 45`, `connect_timeout: 90` |
| Google | навык `google-workspace`, Desktop OAuth client (проект `rapid-airship-499220-t2`), токен `~/.hermes/google_token.json`, `LIVE_CHECK_OK`; все scopes Workspace |
| Утренняя сводка | навык `daily-briefing`, cron `29d9febd70de` «30 6 * * *» (`timezone: Asia/Yekaterinburg`) = **04:30 МСК**, доставка `vk:175934368`, `cron.wrap_response: false`; VK — домашний канал (`/sethome`). Тест 01.11.2026 доставлен |
| Голос (STT) | Timeweb `timeweb/whisper-large-v3`, `stt.language: ru`, ключ через `${TIMEWEB_API_KEY}`; проверено на файле 02.11.2026 |
| Картинки | Timeweb `openai/gpt-image-2` через `image_gen.openai.provider: timeweb`; папка `cache/generated/images/openai_openai` создана (баг со слешем) |
| Obsidian | клон `RudinMaxim/obsidian_store` → `~/obsidian_store` (deploy-ключ `~/.ssh/obsidian_deploy`, alias `github-obsidian`); MCP `obsidian` (server-filesystem 2.1.0, только папка хранилища, `trust: full`); `obsidian-sync.timer` каждые 5 мин; навык `obsidian-para`. Проверено чтение/запись/push 02.11.2026 |
| Модель: рассуждения | `agent.reasoning_effort: low` (с 04.11.2026; `medium` в 2,3 раза медленнее) |
| VK | сообщество Hermes `242841516`, доступ только `175934368` (`VK_ACCESS_POLICY=user_only`), ключ с правами manage+messages(+photos,docs); канал работает с 2026-11-01, ответ ~5 с. `message_event` включён через API 02.11.2026; кнопки подтверждения работают (проверено владельцем 08.11.2026) |
| Telegram | не используется: `api.telegram.org` с сервера недоступен |

## Ограничения от владельца сервера

- Не трогать `/opt/healthy-student`, контейнеры `healthy-student-prod`, `/etc/docker/daemon.json`,
  fail2ban; ufw — только согласованные правила.
- Без согласования не запускать `apt upgrade` и `docker system prune`.
- Локальные модели не запускать: не хватит памяти, упадёт сайт.
- Наружу открыты только 22, 80, 443.
