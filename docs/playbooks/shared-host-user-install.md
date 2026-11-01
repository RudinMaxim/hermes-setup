# Плейбук: Hermes Agent на сервере клиента без root и Docker

Пошаговая инструкция для сотрудника. Сценарий: у клиента уже есть сервер с
продакшеном (сайт, API), и агент ставится **рядом**, ничего не ломая.
Агент живёт под отдельным пользователем `hermes` без sudo и Docker, модель —
только внешняя по API.

> Проверено на эталонной установке 2026-11-01: Ubuntu 26.04, 2 CPU / 3.8 ГБ RAM,
> рядом сайт в Docker с Caddy. Шаги, которые на эталоне **не** проверены до конца,
> помечены ⚠️. Данные эталона: [`instances/healthy-student-vps.md`](instances/healthy-student-vps.md).

## Как читать эту инструкцию

У каждого шага есть пометка **где выполнять**. Это главное, в чём путаются:

| Пометка | Где | Как туда попасть |
|---|---|---|
| 💻 **Локально** | твой компьютер (Windows — Git Bash, macOS/Linux — терминал) | просто открой терминал |
| 🔴 **root** | сервер, под root | `ssh root@<IP>` — **делает владелец** или ты с его письменного разрешения |
| 🟢 **hermes** | сервер, под hermes | `ssh hermes-<client>` (алиас из шага 2) |

Алиас `hermes-<client>` существует **только на твоём компьютере**. Внутри сессии
на сервере он не работает (`Could not resolve hostname`) — выйди (`exit`) и
выполни команду локально.

После каждого шага, где что-то меняется на сервере, проверяй, что прод жив:

```bash
curl -s <HEALTH_URL>      # эталон: {"status":"ok"}
```

## Подходит ли этот сценарий

| Ситуация | Что использовать |
|---|---|
| Отдельный VPS под агента, есть root | Docker-вариант: `README.md`, `setup.sh` |
| Mac mini клиента | `docs/macos-personal-host.md` |
| **Общий сервер с продом, root только у владельца** | **эта инструкция** |

Не начинай, если свободной памяти меньше 1.5 ГБ (`free -m`, колонка `available`).

---

## Шаг 1. Собрать данные у клиента

Отправь клиенту список и не начинай, пока нет ответов:

- [ ] IP сервера, ОС, CPU/RAM/swap, свободный диск.
- [ ] Что работает на сервере, и **адрес health-check** прода (`<HEALTH_URL>`).
- [ ] Открытые порты и кто их занимает (обычно 22/80/443 — веб-сервер сайта).
- [ ] Что нельзя трогать: каталоги, контейнеры, конфиги, firewall.
- [ ] Кто выполняет root-шаги (шаги 3 и 9): владелец сам или даёт доступ.
- [ ] LLM-провайдер и чей ключ. Для серверов в РФ — провайдер, доступный из РФ (шаг 7).
- [ ] Как клиент будет общаться с агентом: веб-интерфейс, домен, VK.
- [ ] Если нужен домен: какой (`hermes.<домен>`), и есть ли доступ к DNS.
- [ ] Если сайт в Docker: доступ к репозиторию сайта (шаг 9).

## Шаг 2. 💻 Создать SSH-ключ для клиента

Для каждого клиента — **отдельный** ключ. Никогда не используй деплой-ключ
клиента или свой личный ключ.

```bash
ssh-keygen -t ed25519 -N "" -C "hermes-agent-installer@<IP>" -f ~/.ssh/hermes_<client>
cat ~/.ssh/hermes_<client>.pub     # эту строку отправить владельцу
```

Добавь в `~/.ssh/config` (файл создай, если его нет):

```
Host hermes-<client>
    HostName <IP>
    User hermes
    IdentityFile ~/.ssh/hermes_<client>
    IdentitiesOnly yes
    ServerAliveInterval 30
```

Не добавляй сюда `LocalForward`: тогда каждый `ssh`/`scp` будет пытаться занять
порт. Туннель поднимается отдельной командой (шаг 8).

## Шаг 3. 🔴 root: создать пользователя hermes

Единственный обязательный root-шаг. Команду можно запускать повторно — она ничего не задвоит.
Подставь `<HEALTH_URL>` и публичный ключ из шага 2 и выполни **локально** (она сама зайдёт на сервер):

```bash
ssh root@<IP> 'set -e
echo "health before: $(curl -s <HEALTH_URL>)"
id hermes 2>/dev/null || useradd -m -s /bin/bash hermes
install -d -m 700 -o hermes -g hermes /home/hermes/.ssh
KEY="<СТРОКА ИЗ hermes_<client>.pub>"
touch /home/hermes/.ssh/authorized_keys
grep -qxF "$KEY" /home/hermes/.ssh/authorized_keys || echo "$KEY" >> /home/hermes/.ssh/authorized_keys
chown hermes:hermes /home/hermes/.ssh/authorized_keys
chmod 600 /home/hermes/.ssh/authorized_keys
loginctl enable-linger hermes
id hermes; loginctl show-user hermes -p Linger
echo "health after: $(curl -s <HEALTH_URL>)"'
```

**Ожидаемо:** `groups=1001(hermes)` (без `sudo` и `docker`), `Linger=yes`, health до и после одинаковый.

`linger` нужен, чтобы сервисы hermes работали без открытой SSH-сессии и после перезагрузки.

Под root **не делаем**: не ставим пакеты, не трогаем Docker и конфиги прода,
не запускаем `apt upgrade` и `docker system prune`.

## Шаг 4. 💻→🟢 Проверить сервер

```bash
ssh hermes-<client> 'id; sudo -n true 2>&1 | head -1; free -m | head -2; df -h ~ | tail -1;
  python3 --version; git --version; which curl; uname -m;
  ls /usr/lib/*/libatomic.so.1; ip link | grep mtu; systemctl --user is-system-running'
```

| Что видим | Норма | Если не так |
|---|---|---|
| sudo | `Sorry… can't do that` | так и задумано |
| `systemctl --user` | `running` | linger не включён → шаг 3 |
| python3, git, curl | есть | попросить владельца поставить |
| `libatomic.so.1` | есть | попросить владельца: `apt install libatomic1` |
| `uname -m` | `x86_64` | для `aarch64` ниже везде `linux-arm64` вместо `linux-x64` |

Проверь, какие внешние сервисы доступны с сервера. Код `000` = недоступен:

```bash
ssh hermes-<client> 'for u in https://nodejs.org/dist/index.json https://registry.npmjs.org/ \
  https://pypi.org/simple/ https://github.com https://api.telegram.org/ https://api.vk.com/ \
  https://ai.reg.cloud/v1/models; do printf "%-40s " $u; \
  curl -sS -o /dev/null -m 12 -w "%{http_code}\n" $u 2>&1 | tail -1; done'
```

Эталон (сервер в РФ): `nodejs.org` и `api.telegram.org` — `000`, остальные отвечают.
Если `nodejs.org` = `000`, на шаге 6 понадобится обход.

## Шаг 5. 💻 Скачать и проверить установщик

Правило: **сначала скачать и прочитать, потом запускать**. Никаких `curl | bash` вслепую на чужом проде.

```bash
mkdir -p ~/hermes-installer && cd ~/hermes-installer
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o install.sh
sha256sum install.sh          # записать в отчёт клиенту
less install.sh               # просмотреть: что качает и куда ставит
scp install.sh hermes-<client>:~/hermes-install.sh
```

Установщик всё ставит в `~/.hermes`: свой `uv`, Python и зависимости, сверенные по хешам. Root ему не нужен.

## Шаг 6. 🟢 Установить Hermes

Запуск в фоне, с пониженным приоритетом, чтобы не мешать проду:

```bash
ssh hermes-<client> 'nohup nice -n 15 ionice -c3 bash ~/hermes-install.sh \
  --skip-setup --skip-browser --skip-computer-use </dev/null > ~/hermes-install.log 2>&1 & echo started'
```

- `--skip-browser` — без Chromium (сотни МБ RAM). Включать, только если клиенту нужен браузер.
- `--skip-setup` — без интерактивного мастера, настраиваем сами в шаге 7.

Следить за ходом (выход — `Ctrl+C`, установку это не остановит):

```bash
ssh hermes-<client> 'tail -f ~/hermes-install.log' | grep -v 'MiB /'
```

**Ожидаемо** (эталон ~10 минут): в конце `✓ Hermes Agent install complete`, в `~/.local/bin` появились `hermes`, `hermes-agent`, `hermes-acp`.

### Если упало с `✗ pm install failed` (типично для РФ)

Посмотри причину:

```bash
ssh hermes-<client> 'grep -v "MiB /" ~/hermes-install.log | grep -i "fail\|error\|✗"'
```

Если там `node: install failed: download failed from https://nodejs.org/...` и
`hermes-assets.nousresearch.com ... 403` — значит, `nodejs.org` заблокирован, а запасное
зеркало Nous не пускает этот регион. Положи тот же архив Node в кеш установщика из
зеркала Huawei. Безопасно: файл сверяется с хешем из `lock.json` Hermes.

Зайди на сервер (`ssh hermes-<client>`) и выполни:

```bash
L=~/.hermes/hermes-agent/pm/lock.json
URL=$(grep -oE 'https://nodejs.org/dist/v[0-9.]+/node-v[0-9.]+-linux-x64.tar.xz' $L | head -1)
SHA=$(grep -B1 "$URL" $L | grep -oE '[a-f0-9]{64}')
VER=$(echo "$URL" | grep -oE 'v[0-9.]+' | head -1)
FILE=$(basename "$URL")
echo "version=$VER sha=$SHA"                      # оба должны быть непустыми
D=~/.hermes/tools/fetch-$SHA; mkdir -p $D
curl -fsSL https://mirrors.huaweicloud.com/nodejs/$VER/$FILE -o $D/node.tmp
echo "$SHA  $D/node.tmp" | sha256sum -c - && mv $D/node.tmp $D/$FILE
```

**Ожидаемо:** `node.tmp: OK`. Если `FAILED` — **не продолжай**, файл подменён или битый.
Затем выйди с сервера (`exit`) и повтори команду установки из начала шага 6.

## Шаг 7. 🟢 Подключить модель

### 7.1. 💻 Положить ключ API в `.env`

Ключи хранятся только в `~/.hermes/.env` с правами 600. Передаём ключ через stdin,
чтобы он не попал в историю команд и список процессов на сервере.
Выполни локально, вставь ключ, когда терминал замолчит, и нажми Enter:

```bash
read -rs KEY && printf '%s\n' "$KEY" | ssh hermes-<client> 'umask 077; read -r K; E=~/.hermes/.env;
  touch $E; grep -v "^REGCLOUD_API_KEY=" $E > $E.new || true;
  echo "REGCLOUD_API_KEY=$K" >> $E.new; mv $E.new $E; chmod 600 $E; ls -l $E'; unset KEY
```

**Ожидаемо:** `-rw------- … /home/hermes/.hermes/.env`.

### 7.2. 🟢 Выбрать провайдера и модель

Пример: reg.cloud «ИИ-модели». Он OpenAI-совместимый, оплачивается в РФ и доступен с российских серверов.
Любой другой OpenAI-совместимый провайдер подключается так же, меняются только адрес и имя переменной.

Зайди на сервер (`ssh hermes-<client>`):

```bash
# список моделей, доступных по ключу
set -a; . ~/.hermes/.env; set +a
curl -s https://ai.reg.cloud/v1/models -H "Authorization: Bearer $REGCLOUD_API_KEY" | python3 -c \
  "import sys,json;[print(m['id']) for m in json.load(sys.stdin)['data']]"

hermes config set providers.regcloud.base_url https://ai.reg.cloud/v1
hermes config set providers.regcloud.key_env REGCLOUD_API_KEY
hermes config set model.provider regcloud
hermes config set model.default claude-5.5-sonnet     # id из списка выше
hermes config set model.base_url https://ai.reg.cloud/v1

hermes -z "Ответь одним словом: работаешь?"
```

**Ожидаемо:** модель отвечает (эталон: `Работаю.`).

### 7.3. 🟢 Запасной провайдер — обязательно

Агрегатор может лечь целиком. На эталоне 01.11.2026 reg.cloud несколько часов отдавал список моделей,
но любая генерация висела, а потом падала с `500`, и чат стоял. Поэтому всегда подключай второго
провайдера. Ключ клади так же, как в 7.1 (переменная `TIMEWEB_API_KEY`).

Эталон: основной Timeweb (`https://api.timeweb.ai/v1`, 120+ моделей, в том числе распознавание речи),
запасной reg.cloud:

```bash
hermes config set providers.timeweb.base_url https://api.timeweb.ai/v1
hermes config set providers.timeweb.key_env TIMEWEB_API_KEY
hermes config set model.provider timeweb
hermes config set model.base_url https://api.timeweb.ai/v1
hermes config set model.default zai/glm-5.3-flash          # id у Timeweb с префиксом вендора
hermes config set fallback_providers '[{"provider": "regcloud", "model": "glm-5.3-flash"}]'
hermes fallback list
systemctl --user restart hermes-dashboard                  # интерфейс подхватывает конфиг при старте
```

Если чат в интерфейсе молчит, а `hermes -z` тоже висит, проверь провайдера напрямую:

```bash
set -a; . ~/.hermes/.env; set +a
curl -sS -m 30 -w "\n%{http_code} %{time_total}s\n" https://api.timeweb.ai/v1/chat/completions \
  -H "Authorization: Bearer $TIMEWEB_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"zai/glm-5.3-flash","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}'
```

Таймаут или `500` при рабочем `/v1/models` означают, что сбой у провайдера, а не у нас: смотри баланс и ключ
в его кабинете, пиши в поддержку.

У «думающих» моделей (GLM, DeepSeek) при маленьком `max_tokens` поле `content` может прийти пустым:
весь лимит ушёл на рассуждение. Это не ошибка.

Если `hermes: command not found` — выполни `source ~/.bashrc` или открой новую SSH-сессию.

## Шаг 8. 🟢 Веб-интерфейс и автозапуск

### 8.1. Создать сервис

На сервере (`ssh hermes-<client>`):

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/hermes-dashboard.service <<'EOF'
[Unit]
Description=Hermes Agent web dashboard
After=network-online.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.local/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build
Restart=on-failure
RestartSec=10
Nice=10
MemoryHigh=1200M
MemoryMax=1600M

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now hermes-dashboard
sleep 10; systemctl --user is-active hermes-dashboard; ss -ltn | grep 9119
```

**Ожидаемо:** `active` и `LISTEN … 127.0.0.1:9119`.

`MemoryMax` страхует прод: если агент начнёт течь, система убьёт его, а не сайт.
На эталоне агент в простое занимает ~170 МБ.

### 8.2. 💻 Открыть через SSH-туннель

```bash
ssh -N -L 9119:127.0.0.1:9119 hermes-<client>
```

Пока команда висит, открой в браузере http://localhost:9119. Пароль не нужен: интерфейс виден только через туннель.

Если нужен адрес вида `https://hermes.<домен>` (например, чтобы открывать с телефона) — шаг 9.
Если хватает туннеля — переходи к шагу 11.

## Шаг 9. Свой домен `hermes.<домен>`

### 9.1. DNS

У регистратора домена создай запись (лучше на домене, **не связанном** с сайтом клиента):

| Тип | Имя | Значение | TTL |
|---|---|---|---|
| A | `hermes` | `<IP>` | 300 |

Проверка (💻, через 5–30 минут): `nslookup hermes.<домен>` → `<IP>`.

### 9.2. 🟢 Логин и пароль для веб-интерфейса

Как только интерфейс слушает не только `127.0.0.1`, Hermes **сам** требует вход.
Настраиваем логин и пароль. На сервере хранится только хеш пароля, сам пароль — нет.

Зайди на сервер (`ssh hermes-<client>`) и выполни, подставив логин:

```bash
USERNAME=<логин>
PW=$(python3 -c "import secrets;print(secrets.token_urlsafe(18))")
HASH=$(printf %s "$PW" | python3 -c '
import sys, hashlib, secrets, base64
s = secrets.token_bytes(16)
dk = hashlib.scrypt(sys.stdin.read().encode(), salt=s, n=2**14, r=8, p=1, dklen=32, maxmem=0)
print("scrypt$16384$8$1$%s$%s" % (base64.b64encode(s).decode(), base64.b64encode(dk).decode()))')
SECRET=$(python3 -c "import secrets;print(secrets.token_hex(32))")
E=~/.hermes/.env; umask 077
grep -v "^HERMES_DASHBOARD_BASIC_AUTH_\|^HERMES_DASHBOARD_PUBLIC_URL=" $E > $E.new || true
cat >> $E.new <<EOF
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$USERNAME
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$HASH
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$SECRET
HERMES_DASHBOARD_PUBLIC_URL=https://hermes.<домен>
EOF
mv $E.new $E; chmod 600 $E
echo "ПАРОЛЬ (сохрани в менеджер паролей, больше нигде его нет): $PW"
```

Той же командой меняется пароль. После неё перезапусти интерфейс:
`systemctl --user restart hermes-dashboard`.

### 9.3. Где работает веб-сервер клиента

Порты 80 и 443 заняты веб-сервером сайта, поэтому домен идёт через него. Определи, где он запущен
(🟢, root не нужен):

```bash
ssh hermes-<client> 'P=$(pgrep -f "caddy run|nginx: master" | head -1); echo pid=$P; cat /proc/$P/cgroup'
```

- `…/docker-<id>.scope` → веб-сервер **в Docker** → шаг 9.4.
- иначе → веб-сервер **на хосте** → шаг 9.5.

### 9.4. Веб-сервер в Docker (эталонный случай)

На эталоне Caddy встроен в образ сайта, а Caddyfile лежит в репозитории сайта и выкатывается его CI.
Поэтому правим **репозиторий сайта через PR**. Править файлы прямо на сервере нельзя: следующий деплой их затрёт.

**a) 🔴 root: узнать сеть контейнера.** Владелец выполняет, `<id>` взять из 9.3:

```bash
ssh root@<IP> 'docker inspect -f "{{.Name}} {{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} gw={{\$v.Gateway}}{{end}}" <id>'
```

Эталон: `/healthy-student-prod-web-1 healthy-student-prod_default gw=172.18.0.1` → подсеть `172.18.0.0/16`.

**b) 🔴 root: разрешить контейнеру ходить к агенту на хосте.** Без этого правила ufw режет запросы:

```bash
ssh root@<IP> 'ufw allow from 172.18.0.0/16 to 172.17.0.1 port 9119 proto tcp && ufw status | grep 9119'
```

**c) 💻 PR в репозиторий сайта.** Работай в отдельной ветке от свежего `main`:

- в `docker-compose` у сервиса веб-сервера:
  ```yaml
      extra_hosts:
        - "host.docker.internal:host-gateway"   # = 172.17.0.1, docker0 хоста
  ```
- в `Caddyfile` отдельный блок (блоки сайта не трогать):
  ```
  hermes.<домен> {
  	reverse_proxy host.docker.internal:9119
  }
  ```
- проверь синтаксис (💻, нужен Docker):
  ```bash
  docker run --rm -e DOMAIN=example.com -v "$PWD/infra/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  ```
  Ожидаемо: `Valid configuration`. На Windows в Git Bash перед командой добавь `MSYS_NO_PATHCONV=1`,
  а вместо `$PWD` используй `$(pwd -W)`.
- открой PR и опиши в нём правило ufw из шага b. **Merge делает клиент**: на эталоне merge в `main` сразу деплоит прод.

Эталонный PR: `cmmb-prototyping-lab/healthy-student#11`.

**d) 🟢 Перевести интерфейс на адрес docker0:**

```bash
ssh hermes-<client> 'sed -i "s/--host 127.0.0.1/--host 172.17.0.1/" ~/.config/systemd/user/hermes-dashboard.service \
  && systemctl --user daemon-reload && systemctl --user restart hermes-dashboard && sleep 10 && ss -ltn | grep 9119'
```

**Ожидаемо:** `LISTEN … 172.17.0.1:9119`. С этого момента туннель из шага 8.2 выглядит так:
`ssh -N -L 9119:172.17.0.1:9119 hermes-<client>`.

### 9.5. Веб-сервер на хосте

Интерфейс остаётся на `127.0.0.1`, ufw не трогаем. Владелец добавляет в конфиг
`reverse_proxy 127.0.0.1:9119` (Caddy) или `proxy_pass http://127.0.0.1:9119;` (nginx) и перезагружает
веб-сервер. Вход по паролю (9.2) в этом случае **сам не включится**: закрой домен паролем на веб-сервере.

### 9.6. 💻 Проверить домен

```bash
curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" https://hermes.<домен>/
curl -s <HEALTH_URL>
```

**Ожидаемо:** `302 -> https://hermes.<домен>/login?next=%2F`, сайт клиента отвечает как раньше.
Открой домен в браузере и войди логином из 9.2.

`/api/status` открывается без входа: это проверка живости, так задумано, конфиг через него не виден.
Остальные `/api/*` без входа отвечают `401`.

## Шаг 9а. 🟢 Gateway как сервис — обязательно

Чат интерфейса и запросы `hermes -z` выполняет **gateway** — отдельный от интерфейса процесс.
Если его не оформить сервисом, он запускается «вручную», зависит от сессии, которая его
запустила, **и не перечитывает конфиг при перезапуске интерфейса**. На эталоне из-за этого
не применилась защита записи в Todoist.

```bash
ssh hermes-<client> 'hermes gateway install --start-now </dev/null; sleep 10; hermes gateway status | head -3'
```

Если сервис в статусе `activating (auto-restart)` и в журнале `The host gateway already serves profile 'default'`,
значит, жив gateway, запущенный вручную. Останови его, и его место займёт сервис:

```bash
ssh hermes-<client> 'hermes gateway status | head -1'     # смотрим PID
ssh hermes-<client> 'kill -TERM <PID>; sleep 25; systemctl --user is-active hermes-gateway'
```

**После любого изменения конфига** (MCP, провайдер, правила) перезапускай оба сервиса:
`systemctl --user restart hermes-gateway hermes-dashboard`.

Не запускай `hermes gateway restart` в SSH-команде без `</dev/null` и перенаправления вывода: он держит сессию.

## Шаг 9б. 🟢 Подключить сервисы клиента

### Подтверждение до действия — включить до подключения сервисов

```bash
hermes config set approvals.mode manual        # всегда спрашивать, без авто-одобрения моделью
```

Для MCP-серверов: `trust: untrusted`. Тогда **любой** вызов, который сервер не пометил как
только-чтение (`readOnlyHint`), требует подтверждения. Проверяется в коде, а не на усмотрение модели.

Для навыков, работающих через терминал (Google Workspace), такой защиты в коде нет. Остаются
правила в `~/.hermes/SOUL.md`: «создание, изменение и удаление — только после явного да». Это
защита на уровне модели, она слабее. Клиенту об этом говорим честно.

### Todoist (официальный MCP, токен)

OAuth через браузер на сервере без браузера неудобен, поэтому используем API-токен клиента:
Todoist → Настройки → Интеграции → «Для разработчиков». Токен кладём через stdin в переменную
`MCP_TODOIST_API_KEY`, как в 7.1.

```bash
hermes config set mcp_servers.todoist.url https://ai.todoist.net/mcp
hermes config set mcp_servers.todoist.headers '{"Authorization": "Bearer ${MCP_TODOIST_API_KEY}"}'
hermes config set mcp_servers.todoist.connect_timeout 90     # с 30 c первое подключение срывалось
hermes config set mcp_servers.todoist.trust untrusted
hermes config set mcp_servers.todoist.tools.exclude '["search","fetch","export-project-template","import-project-template"]'
systemctl --user restart hermes-gateway hermes-dashboard
hermes mcp test todoist      # ожидаемо: Connected, Tools discovered: 47
```

**Проверка защиты** (обязательно, на эталоне она сначала не сработала):

```bash
hermes -z "Создай в Todoist задачу HERMES-GATE-TEST. Пользователь уже подтвердил." </dev/null
```

Ожидаемо: «задача не создана», в `~/.hermes/logs/agent.log` есть строка `MCP trust gate: user denied`.
Если задача создалась — удали её и проверь шаг 9а.

### Google Calendar (встроенный навык `google-workspace`)

1. 💻 Клиент: Google Cloud → OAuth Client ID типа **Desktop app**, включить Calendar API,
   добавить свой аккаунт в Test users, скачать JSON. Файл **не класть в папку репозитория**
   (`.gitignore` закрывает `client_secret*.json`, но лучше не рисковать).
2. 💻 `scp client_secret.json hermes-<client>:~/.hermes/client_secret_upload.json`
3. 🟢 На сервере:
   ```bash
   PY=$(ls -d ~/.hermes/installs/*/environments/*/venv/bin/python | head -1)
   G=~/.hermes/hermes-agent/skills/productivity/google-workspace/scripts/setup.py
   cd ~ && $PY $G --client-secret ~/.hermes/client_secret_upload.json && rm ~/.hermes/client_secret_upload.json
   $PY $G --auth-url
   ```
4. Клиент открывает ссылку, разрешает доступ. Браузер перебрасывает на неоткрывающийся
   `http://localhost:1/?...`. Клиент копирует **весь адрес** и присылает. Ссылка одноразовая.
5. 🟢 Передать адрес через stdin (в нём одноразовый код):
   ```bash
   read -r U; $PY $G --auth-code "$U"; $PY $G --check-live      # ожидаемо: LIVE_CHECK_OK
   chmod 600 ~/.hermes/google_token.json ~/.hermes/google_client_secret.json   # токен создаётся с 664
   ```

Навык просит **все** разрешения Workspace (Gmail, Drive, Docs, Sheets, Contacts), не только Calendar.
В этой версии сузить нельзя. Клиента предупреждаем до шага 4.

### Правила в SOUL.md

Добавь в `~/.hermes/SOUL.md` блок правил между маркерами `<!-- hermes-setup rules v1 -->` и
`<!-- /hermes-setup rules v1 -->`: подтверждение до действия, порядок работы с Todoist (реальные
ID, без угаданных аргументов, поведение при circuit breaker), часовой пояс клиента. Эталонный
текст — в `~/.hermes/SOUL.md` эталонного сервера.

## Шаг 10. ⚠️ Канал VK (опционально)

> Плагин установлен на эталоне, но обмен сообщениями end-to-end **ещё не проверен**.

**Telegram с серверов в РФ не работает**: `api.telegram.org` заблокирован, проверено.
Альтернатива — VK. Плагин сам опрашивает VK (Long Poll), входящие порты не нужны.
`api.vk.com` из РФ доступен.

Плагин сторонний: `web3blind/hermes-vk-platform`, не от Nous. **Перед установкой просмотри код**:
он получает токен сообщества. На эталоне проверен коммит `2443f32` — только stdlib,
сеть только к `api.vk.com` и адресам загрузки файлов, которые выдаёт VK, токен вычищается из логов.

**10.1. Настройки сообщества VK** (делает клиент в браузере):

1. «Управление → Сообщения» — включить сообщения сообщества.
2. «Сообщения → Настройки для бота → Возможности ботов» — включить; разрешить добавлять в чаты, если нужно.
3. «Работа с API → Long Poll API» — включить; типы событий: `message_new`, `message_edit`, `message_event`.
4. «Работа с API → Ключи доступа» — создать ключ с правом «Сообщения сообщества».
5. Узнать: числовой ID сообщества (без минуса) и числовые ID людей, которым можно писать боту.

**10.2. 🟢 Установить плагин:**

```bash
ssh hermes-<client> 'hermes plugins install https://github.com/web3blind/hermes-vk-platform.git --enable
  && git -C ~/.hermes/plugins/vk-platform rev-parse HEAD'
```

Сверь коммит с тем, который ты просмотрел.

**10.3. 💻 Записать токен** (как в 7.1, вставить токен после команды):

```bash
read -rs KEY && printf '%s\n' "$KEY" | ssh hermes-<client> 'umask 077; read -r K; E=~/.hermes/.env;
  grep -v "^VK_GROUP_TOKEN=" $E > $E.new || true; echo "VK_GROUP_TOKEN=$K" >> $E.new;
  mv $E.new $E; chmod 600 $E'; unset KEY
```

**10.4. 🟢 Остальные настройки** — добавить в `~/.hermes/.env` (`nano ~/.hermes/.env`):

```
VK_GROUP_ID=<id сообщества без минуса>
VK_ALLOWED_USERS=<id1>,<id2>
VK_ACCESS_POLICY=user_only
```

**Обязательно** ограничь доступ (`VK_ALLOWED_USERS`): иначе любой пользователь VK получит
доступ к агенту и к оплаченному ключу модели.

**10.5. ⚠️ Запуск gateway и проверка:**

```bash
ssh hermes-<client> 'hermes gateway install; hermes gateway restart; sleep 10;
  hermes gateway status; grep -i "VK:" ~/.hermes/logs/gateway.log | tail -20'
```

Затем клиент пишет боту в VK. Ответ должен прийти. Проверь, что `hermes gateway install`
создал сервис для `systemctl --user` (`systemctl --user list-units | grep -i hermes`) и он переживает перезагрузку.

## Шаг 11. Приёмка

- [ ] Health-check прода одинаковый до и после работ.
- [ ] `id hermes` — нет `sudo` и `docker`; `loginctl show-user hermes -p Linger` = `yes`.
- [ ] `hermes -z "…"` отвечает через выбранного провайдера.
- [ ] `systemctl --user is-active hermes-dashboard` = `active`; переживает перезагрузку сервера
      (согласуй окно с клиентом).
- [ ] `ss -ltn | grep 9119` — только `127.0.0.1` или `172.17.0.1`; снаружи `curl -m 5 http://<IP>:9119` не отвечает.
- [ ] Если делали домен: без входа — страница логина, после входа — интерфейс, сайт клиента работает.
- [ ] `stat -c %a ~/.hermes/.env` = `600`; ключи и пароли не попали в чаты, логи, PR и репозиторий.
- [ ] Неиспользованные токены, которые клиент присылал в чат, отозваны.

## Шаг 12. Отчёт клиенту

```
Готово: Hermes Agent на <IP>, пользователь hermes (без sudo/Docker).
Модель: <провайдер> / <модель>.
Доступ: https://hermes.<домен> (логин <логин>) | SSH-туннель.
Прод: health-check OK до и после.
Изменения под root: пользователь hermes + linger[, правило ufw 9119 из подсети <...>].
Изменения в репозитории сайта: <ссылка на PR или «нет»>.
Ресурсы: ~170 МБ RAM в простое, лимит 1.6 ГБ; ~1.5 ГБ диска.
Установщик: NousResearch install.sh, sha256 <...>; версия Hermes <hermes --version>.
Откат: раздел «Откат» инструкции.
```

---

## Обслуживание

| Задача | Где | Команда |
|---|---|---|
| Статус | 🟢 | `systemctl --user status hermes-dashboard`; `hermes status` |
| Логи интерфейса | 🟢 | `journalctl --user -u hermes-dashboard -n 100` |
| Перезапуск | 🟢 | `systemctl --user restart hermes-dashboard` |
| Сменить модель | 🟢 | `hermes config set model.default <id>` |
| Сменить пароль интерфейса | 🟢 | шаг 9.2, затем перезапуск |
| Обновить Hermes | 🟢 | `nice -n 15 hermes update` (в РФ может снова понадобиться обход Node из шага 6) |
| Диагностика | 🟢 | `hermes doctor` |

## Откат

```bash
# 🟢 под hermes
systemctl --user disable --now hermes-dashboard
rm ~/.config/systemd/user/hermes-dashboard.service
hermes uninstall                     # или: rm -rf ~/.hermes ~/.local/bin/hermes*

# 🔴 под root (если делали домен через Docker)
ufw delete allow from <подсеть> to 172.17.0.1 port 9119 proto tcp
# + revert PR в репозитории сайта (merge revert делает клиент)

# 🔴 под root, полное удаление
loginctl disable-linger hermes; userdel -r hermes
```

## Частые проблемы

| Симптом | Причина | Что делать |
|---|---|---|
| `Could not resolve hostname hermes-<client>` | команда запущена на сервере, а алиас есть только локально | `exit`, выполнить на своём компьютере |
| `✗ pm install failed`, `nodejs.org … handshake timed out` | блокировка `nodejs.org` в РФ | обход в шаге 6 |
| `hermes-assets.nousresearch.com … 403` | Cloudflare не пускает этот регион | то же, обход в шаге 6 |
| `hermes: command not found` | PATH ещё не обновлён | `source ~/.bashrc` или новая SSH-сессия |
| `ModuleNotFoundError: httpx` при `from plugins…` | системный python3 не видит зависимости Hermes | хеш пароля считать stdlib-скриптом из 9.2 |
| домен отдаёт `502` | интерфейс не запущен или слушает не `172.17.0.1` | `systemctl --user status hermes-dashboard`, `ss -ltn \| grep 9119` |
| домен висит / `504` | нет правила ufw из 9.4b | проверить `ufw status \| grep 9119` (root) |
| Telegram не подключается | `api.telegram.org` заблокирован в РФ | веб-интерфейс или VK (шаг 10) |
| локальные модели, whisper | мало RAM, общий сервер с продом | только внешние API (STT: `scripts/vps/openrouter-stt.py`) |
| агент-исполнитель (Claude Code и т.п.) отказывается выполнять root-команды на проде | политики безопасности агента | так и должно быть: root-шаги выполняет человек по командам из этой инструкции |
