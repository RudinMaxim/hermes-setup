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
| Модель | основной: Timeweb `https://api.timeweb.ai/v1`, `zai/glm-5.3-flash`, ключ `TIMEWEB_API_KEY` |
| Запасной провайдер | reg.cloud `https://ai.reg.cloud/v1`, `glm-5.3-flash`, ключ `REGCLOUD_API_KEY` (`fallback_providers`) |
| Интерфейс | сервис `hermes-dashboard` (`systemctl --user`), слушает `172.17.0.1:9119` |
| Домен | https://hermes.turni.ru, логин `maksim` |
| Прокси | Caddyfile в репо `cmmb-prototyping-lab/healthy-student`, PR #11 (merged 2026-11-01) |
| ufw | `172.17.0.1 9119/tcp ALLOW 172.18.0.0/16` (добавлено 2026-11-01) |
| Туннель | `ssh -N -L 9119:172.17.0.1:9119 hermes-vps` → http://localhost:9119 |
| Gateway | сервис `hermes-gateway` (`systemctl --user`), с 2026-11-01 |
| Подтверждения | `approvals.mode: manual`; Todoist `trust: untrusted` (проверено: запись без подтверждения блокируется); правила в `~/.hermes/SOUL.md` (rules v3 — +формат под канал, 02.11.2026); в VK отключён `code_execution`, `approvals.deny` на вставки кода |
| Todoist | официальный MCP `ai.todoist.net/mcp`, токен `MCP_TODOIST_API_KEY`, 47 инструментов, `timeout: 45`, `connect_timeout: 90` |
| Google | навык `google-workspace`, Desktop OAuth client (проект `rapid-airship-499220-t2`), токен `~/.hermes/google_token.json`, `LIVE_CHECK_OK`; все scopes Workspace |
| Утренняя сводка | навык `daily-briefing`, cron `29d9febd70de` «30 6 * * *» (`timezone: Asia/Yekaterinburg`) = **04:30 МСК**, доставка `vk:175934368`, `cron.wrap_response: false`; VK — домашний канал (`/sethome`). Тест 01.11.2026 доставлен |
| Голос (STT) | Timeweb `timeweb/whisper-large-v3`, `stt.language: ru`, ключ через `${TIMEWEB_API_KEY}`; проверено на файле 02.11.2026 |
| Картинки | Timeweb `openai/gpt-image-2` через `image_gen.openai.provider: timeweb`; папка `cache/generated/images/openai_openai` создана (баг со слешем) |
| Модель: рассуждения | `agent.reasoning_effort: medium` |
| VK | сообщество Hermes `242841516`, доступ только `175934368` (`VK_ACCESS_POLICY=user_only`), ключ с правами manage+messages(+photos,docs); канал работает с 2026-11-01, ответ ~5 с. `message_event` включён через API 02.11.2026 (нажатие кнопок ещё не проверено) |
| Telegram | не используется: `api.telegram.org` с сервера недоступен |

## Ограничения от владельца сервера

- Не трогать `/opt/healthy-student`, контейнеры `healthy-student-prod`, `/etc/docker/daemon.json`,
  fail2ban; ufw — только согласованные правила.
- Без согласования не запускать `apt upgrade` и `docker system prune`.
- Локальные модели не запускать: не хватит памяти, упадёт сайт.
- Наружу открыты только 22, 80, 443.
