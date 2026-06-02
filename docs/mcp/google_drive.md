# Google Drive MCP — ручное подключение

Поиск и чтение файлов в Google Drive через хостовый MCP Google
(`https://drivemcp.googleapis.com/mcp/v1`). Авторизация — OAuth, поэтому
подключается **вручную через агента**: автоматического OAuth-логина в
`setup.sh` нет.

Google Drive MCP — это удалённый HTTP MCP. Для него не нужно устанавливать npm
пакет и не нужно копировать отдельный MCP-файл в контейнер. Нужно:

1. Получить OAuth `client_id` и `client_secret` в Google Cloud.
2. Добавить MCP-запись в Hermes config (`/opt/data/config.yaml` внутри
   контейнера).
3. Пройти OAuth-login через ссылку, которую Hermes покажет в чате.

## 0. Проверить, что Hermes запущен
На машине, где установлен Hermes, выполни:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

В списке должен быть контейнер `hermes` со статусом `Up ...`.

Если Docker пишет, что daemon не запущен, сначала запусти Docker / Docker
Desktop или подключись к VPS, где реально работает Hermes. Пока Docker не
отвечает, команды `docker exec ...` не сработают.

## 1. OAuth-креды из Google Cloud Console
1. https://console.cloud.google.com → создай (или выбери) проект.
2. **APIs & Services → Library** → включи **Google Drive API**.
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
   - Тип: **Desktop app** (выдаёт client id + secret для loopback-redirect).
4. Сохрани `client_id` (`...apps.googleusercontent.com`) и `client_secret`.
5. На экране **OAuth consent screen** добавь свой Google-аккаунт в **Test users**
   (иначе авторизация вернёт ошибку доступа).

Положи креды в `config/.env`, чтобы не светить их в командах:
```
GOOGLE_DRIVE_OAUTH_CLIENT_ID=...apps.googleusercontent.com
GOOGLE_DRIVE_OAUTH_CLIENT_SECRET=...
```

Важно: `config/.env` не копируется внутрь контейнера как файл. Docker Compose
читает этот файл при создании контейнера и прокидывает значения как переменные
окружения процесса. Если ты добавил новые переменные в уже существующий
`config/.env`, пересоздай контейнер:

```bash
docker compose -f config/docker-compose.yml up -d --force-recreate hermes
```

Проверить, что переменные попали в контейнер:

```bash
docker exec hermes printenv GOOGLE_DRIVE_OAUTH_CLIENT_ID
```

## 2. Зарегистрировать MCP у Hermes
Есть два рабочих способа.

### Вариант A: попросить агента
Проще всего — попросить Hermes-агента в чате:

```bash
docker exec -it hermes hermes chat
```

> Добавь HTTP MCP-сервер `google_drive` с url
> `https://drivemcp.googleapis.com/mcp/v1`, auth `oauth`, client_id и
> client_secret возьми из переменных окружения `GOOGLE_DRIVE_OAUTH_CLIENT_ID` и
> `GOOGLE_DRIVE_OAUTH_CLIENT_SECRET`, scope
> `https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file`.
> Проверь конфиг и перезапусти контейнер Hermes, если это нужно.

Если агент не смог корректно записать OAuth-блок, используй ручной вариант.

### Вариант B: скопировать config.yaml на хост и отредактировать там
Hermes хранит свой конфиг в `$HERMES_HOME/config.yaml`. В этом compose-файле
`HERMES_HOME=/opt/data`, значит полный путь внутри контейнера:

```text
/opt/data/config.yaml
```

Сначала выйди из контейнера, если ты уже внутри:

```bash
exit
```

Скопируй конфиг Hermes из контейнера на хост:

```bash
docker cp hermes:/opt/data/config.yaml ./config.hermes.yaml
cp ./config.hermes.yaml ./config.hermes.yaml.bak
```

Открой `./config.hermes.yaml` любым редактором на хосте. Например:

```bash
vim ./config.hermes.yaml
```

Если `vim` неудобен, скачай файл через SFTP/VS Code Remote, отредактируй
локально и загрузи обратно на сервер.

Добавь или расширь секцию `mcp_servers`. Если секция уже есть, не создавай
вторую `mcp_servers`, а добавь только вложенный блок `google_drive`:

```yaml
mcp_servers:
  google_drive:
    enabled: true
    url: https://drivemcp.googleapis.com/mcp/v1
    auth: oauth
    oauth:
      client_id: "<client_id>"          # реальное значение, Hermes не разворачивает ${VARS} в oauth
      client_secret: "<client_secret>"
      scope: "https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file"
```

В OAuth-блоке впиши реальные `client_id` и `client_secret`, а не
`${GOOGLE_DRIVE_OAUTH_CLIENT_ID}`. На текущем Hermes OAuth-настройки могут не
разворачивать переменные окружения.

Перед тем как возвращать файл в контейнер, проверь, что ты не затёр остальные
настройки:

```bash
diff -u ./config.hermes.yaml.bak ./config.hermes.yaml
```

В выводе `diff` должны быть только строки, которые добавляют или меняют
`google_drive`. Если там пропали другие секции (`model`, `providers`,
`gateways`, другие MCP и т.п.), не копируй файл обратно. Восстанови его из
backup:

```bash
cp ./config.hermes.yaml.bak ./config.hermes.yaml
```

Верни файл обратно в контейнер, проверь конфиг и перезапусти Hermes:

```bash
docker cp ./config.hermes.yaml hermes:/opt/data/config.yaml
docker exec -u root hermes chown hermes:hermes /opt/data/config.yaml
docker exec -u root hermes chmod 600 /opt/data/config.yaml
docker exec -u root hermes ls -l /opt/data/config.yaml
docker exec hermes hermes config check
docker restart hermes
```

`docker cp ./config.hermes.yaml hermes:/opt/data/config.yaml` заменяет весь
`config.yaml` внутри контейнера. Это нормально только если `config.hermes.yaml`
был скопирован из контейнера и ты аккуратно изменил в нём только нужный блок.
После копирования мы явно возвращаем владельца `hermes:hermes`, иначе Hermes
может получить `Permission denied` и откатиться на default config без MCP.
В выводе `ls -l` владелец должен быть `hermes hermes`, например:

```text
-rw------- 1 hermes hermes ... /opt/data/config.yaml
```

Если там `root root`, не запускай `mcp test`: сначала повтори `chown` и
`chmod`.

### Если хочешь редактировать прямо внутри контейнера
В контейнере может не быть `nano`. Проверь доступные редакторы:

```bash
docker exec -it hermes bash
command -v nano || command -v vi || command -v vim
```

Если команда ничего не вывела, редактора внутри контейнера нет. Используй
вариант с `docker cp` выше. Не устанавливай пакеты в контейнер ради разовой
правки: после пересоздания контейнера они могут пропасть.

## 3. Пройти OAuth через агента
`hermes mcp login` не всегда доводит Google-авторизацию до конца, поэтому
первую авторизацию лучше запускать через CLI-чат внутри контейнера, а не через
Telegram. Так проще увидеть OAuth-ссылку и вставить callback URL:

```bash
docker exec -it hermes hermes chat
```
> Используй MCP `google_drive`: вызови `list_recent_files` и покажи последние
> 5 файлов из моего Google Drive.

1. Hermes напечатает ссылку на `accounts.google.com` — открой её в браузере.
2. Авторизуйся под аккаунтом из **Test users**.
3. Google перенаправит на `http://127.0.0.1:.../?code=...` — скопируй **весь**
   URL из адресной строки.
4. Вставь его обратно в чат, когда Hermes попросит callback URL.

После успешного OAuth можно повторять запросы уже из Telegram.

## 4. Проверка
```bash
docker exec hermes hermes mcp test google_drive
```
Или прямо в чате: «Найди в Google Drive последние документы».

Если `mcp test` пишет, что сервер не настроен, проверь:

```bash
docker exec hermes hermes mcp list
docker exec hermes sed -n '/mcp_servers:/,$p' /opt/data/config.yaml
```

Если OAuth не открывается или Google возвращает ошибку доступа, проверь, что:

- Google Drive API включён в выбранном Google Cloud project.
- OAuth client создан как **Desktop app**.
- Твой Google-аккаунт добавлен в **OAuth consent screen → Test users**.
- В `scope` нет опечаток.

Если Hermes в Telegram отвечает только `I'm sorry, but I cannot assist with that
request`, сначала проверь тот же запрос в CLI-чате:

```bash
docker exec -it hermes hermes chat
```

Сформулируй явно, что нужно использовать MCP:

```text
Используй MCP google_drive и вызови list_recent_files. Покажи последние 5 файлов.
```

Если CLI-чат показывает OAuth-ссылку — авторизация ещё не пройдена. Пройди её
в CLI, затем повтори запрос в Telegram. Если CLI-чат работает, а Telegram всё
ещё отказывает, проблема уже в Telegram gateway, а не в Google Drive MCP. См.
[`../gateways/telegram.md`](../gateways/telegram.md), раздел про принудительный
restart gateway.

## Orphan containers warning
Предупреждения вида:

```text
Found orphan containers ([mcp-playwright]) for this project
Found orphan containers ([hermes]) for this project
```

означают, что Docker Compose видит контейнеры, которых нет в текущем compose-файле
или профиле. Это не связано напрямую с Google Drive MCP.

Не запускай `--remove-orphans` вслепую из случайной compose-команды: если
запустить его только с MCP compose-файлом, Compose может посчитать `hermes`
лишним контейнером. Убирать orphan-контейнеры лучше отдельно, когда понятно,
какой compose-файл сейчас используется.

## Отключение
Поставь `enabled: false` для `google_drive` в `config.yaml` (или попроси агента
удалить сервер), затем выполни:

```bash
docker exec hermes hermes config check
docker restart hermes
```
