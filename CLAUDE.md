# hermes-setup — контекст для агента

Общайся с владельцем по-русски. Если направление понятно, выполняй без лишних подтверждений. Коммить прямо в `main`, без feature-веток. Пушить только по просьбе.

## Что это за проект

1. **Установщик Hermes Agent.** Изначально — идемпотентные bash-скрипты для установки Hermes Agent (Nous Research) на VPS через Docker: `setup.sh`, `scripts/`, `config/`, `tests/` (Bats).
2. **Плейбук и база знаний.** Сейчас основная работа — плейбук для продажи настройки ИИ-агента как аутсорс-услуги: `docs/playbooks/`.
3. **Боевой агент владельца.** Работает на общем сервере, его карточка — `docs/playbooks/instances/healthy-student-vps.md`.

Ключевые файлы:
- `docs/playbooks/agent-files.md` — эталонная конфигурация:
  - команды `hermes config set`;
  - сжатие контекста, бюджеты;
  - сравнение 12 моделей Timeweb в ₽ за сценарий.
- `docs/playbooks/instances/healthy-student-vps.md` — актуальное состояние боевого агента.
- `docs/playbooks/shared-host-user-install.md` — установка без root и Docker.
- `docs/playbooks/channels.md`, `docs/playbooks/soul-rules.md` — каналы и правила личности агента.
- Юнит-экономика услуги в Obsidian: `C:\Users\rudin\core\obsidian_store\1. Projects\Личное\ИИ сотрудник или команда\03 Финансы и экономика\Юнит-экономика.md`. В §12 — замер «рубли на сценарий» от 08.11.2026.

## Боевой сервер 80.78.242.246 (общий с healthy-student.ru)

- Вход: `ssh hermes-vps` под пользователем `hermes`, ключ `~/.ssh/hermes_vps`.
- SSH иногда рвётся. Помощник с повторами: `scripts/vps/sshr.sh '<команда>'`. Он буферизует вывод.
- Hermes 0.23.0 (с 09.11.2026), установлен нативно в `~/.hermes`. Сервисы systemd `--user`:
  - `hermes-gateway` — заодно отдаёт новый чат-интерфейс (Webapp) на 127.0.0.1:9120;
  - `hermes-dashboard` — админка;
  - `hermes-webapp-forward` — проброс 172.17.0.1:9120 для Caddy;
  - `hermes-integrations-check.timer` — проверка токенов, пишет в VK при поломке.
- Веб-доступ: домен hermes.turni.ru, оба интерфейса закрыты логином и паролем `maksim`. Сейчас домен ведёт на админку. После PR #12 в репозитории сайта будет так: `/` — чат, `/admin/` — админка. Чат через туннель: `bash scripts/vps/webapp.sh`.
- Сроки токенов и переподключение: `docs/playbooks/integration-tokens.md`.
- Логи: `~/.hermes/logs/agent.log`. Расход токенов: `~/.hermes/state.db`, таблица `sessions`:
  - поля `input_tokens`, `cache_read_tokens`, `output_tokens`, `api_call_count`, `tool_call_count`;
  - в `model_config` есть признак `fallback_active`.
- Тестовый прогон: `hermes chat --oneshot -q "..." --provider timeweb -m <model>`.

### Правила владельца сервера (обязательны)

- Нужны права администратора — остановись и попроси владельца, ничего не обходи.
- Модель только через внешний API. Локальные модели не запускать.
- Ключи хранить только в `~/.hermes/.env` (chmod 600). Не коммитить их и не выводить в логи.
- Веб-интерфейс слушает только 127.0.0.1. ufw и fail2ban не трогать.
- Не трогать:
  - `/opt/healthy-student`;
  - Docker-контейнеры проекта `healthy-student-prod`;
  - `/etc/docker/daemon.json`.
- Не запускать `docker system prune` и `apt upgrade`.
- До и после работы проверять, что сайт жив: `curl -s https://healthy-student.ru/api/v1/health` → `{"status":"ok"}`.
- **Правило владельца агента: не перезапускать агента, пока он ведёт живой диалог.**
  - Сначала проверь хвост `agent.log` на `inbound message` / `response ready`.
  - Перезапускать только в простое.
  - Перед правкой `config.yaml` делать бэкап `config.yaml.bak-<дата>-<тема>`.

### Текущая конфигурация (08.11.2026)

- **Модели:**
  - основная — `anthropic/claude-haiku-5-5` через провайдера `timeweb`, около 2,1 ₽ за сценарий «что у меня сегодня»;
  - запасные — `gemini/gemini-3.5-flash-lite` (timeweb), затем `glm-5.3-flash` (regcloud);
  - `agent.reasoning_effort low`.
- **Сжатие контекста:**
  - `threshold_tokens` 48000;
  - `protect_last_n` 8;
  - `proactive_prune_tokens` 20000;
  - `tool_budget.mcp_result_size_chars` 15000.
- **Каналы:** VK (кнопки работают), веб-интерфейс.
- **Интеграции:**
  - Google Calendar (навык google-workspace);
  - Todoist MCP (оставлено 26 инструментов);
  - Obsidian.
- **Расписание и медиа:** утренняя сводка в 04:30 МСК, STT, генерация картинок.
- **Биллинг Timeweb:**
  - кешированные токены оплачиваются по полной цене;
  - стоимость = (input + cache) × цена входа + output × цена выхода.
  - Модели сравнивай реальным прогоном сценария, а не ценой за токен.

## Открытые задачи

Полный бэклог репозитория — `docs/tasks/backlog.md` (с 08.11.2026 задачи этого репо живут там, а не в Todoist владельца). Ниже — только горящее.

- **Демо-видео для сайта (блокирует запуск лендинга)** — план и сценарии: `docs/playbooks/demo-videos.md`. Отдельный профиль `demo`, только синтетические данные, канал VK, ускорение с подписью.

- **Todoist `6hwqrJ8cmjwhwG6Q`** (до 09.11):
  - замерить ₽ утренней сводки и сценария «перенеси задачу» на haiku, проверить запрос подтверждения;
  - починить таймаут 45 с у Todoist MCP `find-tasks` на запросе просроченных задач. Это сбой сервиса, а не модели;
  - сделать уведомление о низком балансе Timeweb.
- **Google-токен умер 09.11 (`invalid_grant`, режим Testing, 7 дней).** 👤 Владелец переводит OAuth-приложение в Production (проект `rapid-airship-499220-t2`), затем авторизация заново и `HC_GOOGLE_MODE=production` в `.env`.
- **PR #12 в `cmmb-prototyping-lab/healthy-student`** (чат на `/`, админка на `/admin`). 👤 Сначала ufw `allow from 172.18.0.0/16 to 172.17.0.1 port 9120 proto tcp`, потом мерж. После выкатки поставить `HERMES_DASHBOARD_PUBLIC_URL=https://hermes.turni.ru/admin`, перезапустить dashboard, проверить оба адреса.
- Переподключение Google без нас (ссылка в VK или подключения в Webapp) — не сделано.
- Протестировать `cdp_url` — подключение к Chrome клиента.
- Действие владельца: отключить вход по паролю в SSH.
- Не запушено:
  - коммиты `main` после `39cf90a`;
  - ветка `docs/outsourcing-costs-invoice` в репозитории corp.
