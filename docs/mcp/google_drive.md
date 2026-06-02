# Google Drive MCP — ручное подключение

Поиск и чтение файлов в Google Drive через хостовый MCP Google
(`https://drivemcp.googleapis.com/mcp/v1`). Авторизация — OAuth, поэтому
подключается **вручную через агента**: автоматического OAuth-логина в
`setup.sh` нет.

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

## 2. Зарегистрировать MCP у Hermes
Проще всего — попросить агента в чате:
```bash
docker exec -it hermes hermes chat
```
> Добавь HTTP MCP-сервер `google_drive` с url
> `https://drivemcp.googleapis.com/mcp/v1`, auth `oauth`, client_id и
> client_secret возьми из переменных окружения `GOOGLE_DRIVE_OAUTH_CLIENT_ID` и
> `GOOGLE_DRIVE_OAUTH_CLIENT_SECRET`, scope
> `https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file`.
> Перезагрузи конфиг.

Либо вручную в `$HERMES_HOME/config.yaml` (на текущем образе `/opt/data`):
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
```bash
docker exec hermes hermes config reload
```

## 3. Пройти OAuth через агента
`hermes mcp login` не всегда доводит Google-авторизацию до конца, поэтому
запускаем её, попросив агента реально воспользоваться MCP:

```bash
docker exec -it hermes hermes chat
```
> Воспользуйся google_drive MCP: найди в моём Google Drive файлы с именем "test".

1. Hermes напечатает ссылку на `accounts.google.com` — открой её в браузере.
2. Авторизуйся под аккаунтом из **Test users**.
3. Google перенаправит на `http://127.0.0.1:.../?code=...` — скопируй **весь**
   URL из адресной строки.
4. Вставь его обратно в чат, когда Hermes попросит callback URL.

## 4. Проверка
```bash
docker exec hermes hermes mcp test google_drive
```
Или прямо в чате: «Найди в Google Drive последние документы».

## Отключение
Поставь `enabled: false` для `google_drive` в `config.yaml` (или попроси агента
удалить сервер) и `docker exec hermes hermes config reload`.
