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
| Модель | reg.cloud `https://ai.reg.cloud/v1`, `claude-5.5-sonnet`, ключ `REGCLOUD_API_KEY` |
| Интерфейс | сервис `hermes-dashboard` (`systemctl --user`), слушает `172.17.0.1:9119` |
| Домен | https://hermes.turni.ru, логин `maksim` |
| Прокси | Caddyfile в репо `cmmb-prototyping-lab/healthy-student`, PR #11 (merged 2026-11-01) |
| ufw | `172.17.0.1 9119/tcp ALLOW 172.18.0.0/16` (добавлено 2026-11-01) |
| Туннель | `ssh -N -L 9119:172.17.0.1:9119 hermes-vps` → http://localhost:9119 |
| VK | плагин `vk-platform` @ `2443f32` установлен и включён; токен/ID ещё не заданы, gateway не запущен |
| Telegram | не используется: `api.telegram.org` с сервера недоступен |

## Ограничения от владельца сервера

- Не трогать `/opt/healthy-student`, контейнеры `healthy-student-prod`, `/etc/docker/daemon.json`,
  fail2ban; ufw — только согласованные правила.
- Без согласования не запускать `apt upgrade` и `docker system prune`.
- Локальные модели не запускать: не хватит памяти, упадёт сайт.
- Наружу открыты только 22, 80, 443.
