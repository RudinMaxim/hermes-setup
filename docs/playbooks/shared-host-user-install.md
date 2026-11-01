# Плейбук: Hermes Agent на чужом сервере без root и Docker

Сценарий для аутсорс-внедрения: у клиента уже есть сервер, на нём крутится
продакшен (сайт, API), и агент ставится **рядом**, не мешая ему. Агент живёт
под отдельным непривилегированным пользователем, модель — только внешняя (API).

> Эталонный прогон: Ubuntu 26.04, 2 CPU / 3.8 ГБ RAM / 2 ГБ swap, рядом сайт
> на Caddy + Docker. Статус шагов отмечен по факту этого прогона.

## 0. Когда применять, а когда нет

| Ситуация | Контур |
|---|---|
| Выделенный VPS под агента, есть root | Docker-контур: `README.md`, `setup.sh` |
| Mac mini клиента | `docs/macos-personal-host.md` |
| **Общий сервер с продом, root только у владельца** | **этот плейбук** |

Не применять, если свободной RAM < 1.5 ГБ — агент и прод начнут бороться за память.

## 1. Intake: что узнать у владельца до начала

Отправь клиенту этот список и не начинай, пока нет ответов:

- [ ] IP, ОС и версия, CPU/RAM/swap, свободный диск.
- [ ] Что уже работает на сервере (сайт, БД, контейнеры) и **URL health-check**,
      по которому мы проверяем «прод жив» до и после работ.
- [ ] Открытые порты и чем заняты (обычно 22/80/443 — веб-сервер).
- [ ] MTU сети (часто 1450 у облачных провайдеров — влияет на загрузки).
- [ ] Список «не трогать»: директории, контейнеры, конфиги, firewall.
- [ ] Кто выполняет root-шаги: владелец сам или даёт временный доступ.
- [ ] Какой LLM-провайдер и чей ключ (клиента или наш), бюджет.
- [ ] Каналы связи с агентом: Telegram / Discord / только CLI.

## 2. Ключ агента

Для каждого клиента — **отдельный** ключ, никогда не деплой-ключ клиента и не
личный ключ исполнителя:

```bash
ssh-keygen -t ed25519 -N "" -C "hermes-agent-installer@<SERVER_IP>" -f ~/.ssh/hermes_<client>
```

`~/.ssh/config`:

```
Host hermes-<client>
    HostName <SERVER_IP>
    User hermes
    IdentityFile ~/.ssh/hermes_<client>
    IdentitiesOnly yes
    ServerAliveInterval 30
```

Туннель к веб-интерфейсу поднимай отдельной командой (см. §8), а не через
`LocalForward` в конфиге: иначе каждый служебный `ssh`/`scp` пытается занять порт.

## 3. Root-шаг (выполняет владелец или мы с его разрешения)

Единственное, что делается под root. Идемпотентно, можно прогонять повторно:

```bash
ssh root@<SERVER_IP> 'set -e
echo "health before: $(curl -s <HEALTH_URL>)"
id hermes 2>/dev/null || useradd -m -s /bin/bash hermes
install -d -m 700 -o hermes -g hermes /home/hermes/.ssh
KEY="<PUBKEY>"
touch /home/hermes/.ssh/authorized_keys
grep -qxF "$KEY" /home/hermes/.ssh/authorized_keys || echo "$KEY" >> /home/hermes/.ssh/authorized_keys
chown hermes:hermes /home/hermes/.ssh/authorized_keys
chmod 600 /home/hermes/.ssh/authorized_keys
loginctl enable-linger hermes
id hermes; loginctl show-user hermes -p Linger
echo "health after: $(curl -s <HEALTH_URL>)"'
```

Ожидаемо: `groups=…(hermes)` без `sudo`/`docker`, `Linger=yes`, health до и после одинаковый.

Чего **не** делаем под root: не ставим пакеты, не трогаем firewall, Docker,
конфиги прода, не делаем `apt upgrade` / `docker system prune`.

## 4. Pre-flight под `hermes`

```bash
ssh hermes-<client> 'id; sudo -n true 2>&1 | head -1; free -m | head -2; df -h ~ | tail -1;
  python3 --version; git --version; which curl; uname -m;
  ls /usr/lib/*/libatomic.so.1; ip link | grep mtu; systemctl --user is-system-running'
```

| Проверка | Ожидание | Если нет |
|---|---|---|
| sudo | отказ | ок, так и задумано |
| `systemctl --user` | `running` | владелец не включил linger → §3 |
| git, curl | есть | просить владельца поставить |
| libatomic.so.1 | есть | нужен для Node.js; просить `apt install libatomic1` |
| ffmpeg | опционально | нужен для голосовых; просить владельца |

## 5. Установка

Официальный установщик ставит всё в `~/.hermes` (свой pinned `uv`, Python,
зависимости по `uv.lock`), root не нужен.

Правило: **сначала скачать и прочитать, потом запускать** — никаких `curl | bash`
вслепую на чужом проде.

```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o install.sh
sha256sum install.sh          # зафиксировать в отчёте клиенту
scp install.sh hermes-<client>:~/hermes-install.sh
ssh hermes-<client> 'nohup nice -n 15 ionice -c3 bash ~/hermes-install.sh \
    --skip-setup --skip-browser --skip-computer-use </dev/null > ~/hermes-install.log 2>&1 &'
```

- `nice`/`ionice` — установка не отъедает CPU/диск у прода.
- `--skip-browser` — без Chromium (сотни МБ RAM); браузер включаем, только если клиенту нужен.
- `--skip-setup` — без интерактивного мастера, конфиг пишем сами (§6).

Эталон: ~10 минут, ~1.5 ГБ в `~/.hermes`, RAM во время сборки web UI до ~700 МБ.

**Сервер в РФ: `nodejs.org` недоступен** (TLS handshake timeout; ping при этом идёт — это
блокировка, а не MTU), а запасное зеркало `hermes-assets.nousresearch.com` отдаёт 403 (Cloudflare).
Установка падает с `✗ pm install failed`. Лечится подкладкой того же tarball в кеш `pm`
(байты сверяются с `pm/lock.json`, поэтому зеркало безопасно):

```bash
L=~/.hermes/hermes-agent/pm/lock.json
SHA=$(grep -B1 'node-v.*-linux-x64.tar.xz"' $L | grep -oE '[a-f0-9]{64}')
VER=26.12.1   # из того же URL в lock.json
D=~/.hermes/tools/fetch-$SHA; mkdir -p $D
curl -fsSL https://mirrors.huaweicloud.com/nodejs/v$VER/node-v$VER-linux-x64.tar.xz -o $D/n.tmp
echo "$SHA  $D/n.tmp" | sha256sum -c - && mv $D/n.tmp $D/node-v$VER-linux-x64.tar.xz
# и перезапустить установщик той же командой
```

Перед установкой проверь доступность: `nodejs.org`, `registry.npmjs.org`, `pypi.org`, `github.com`,
`api.telegram.org`, endpoint LLM-провайдера (`curl -m 12 -o /dev/null -w '%{http_code}'`).

## 6. Конфигурация

Ключи — только в `~/.hermes/.env` (права 600), передавать через stdin, не аргументом команды:

```bash
printf '%s
' "$KEY" | ssh hermes-<client> 'umask 077; read -r K; E=~/.hermes/.env;
  grep -v "^REGCLOUD_API_KEY=" $E > $E.new || true; echo "REGCLOUD_API_KEY=$K" >> $E.new; mv $E.new $E; chmod 600 $E'
```

Любой OpenAI-совместимый провайдер (пример — reg.cloud «ИИ-модели», оплата в РФ):

```bash
hermes config set providers.regcloud.base_url https://ai.reg.cloud/v1
hermes config set providers.regcloud.key_env REGCLOUD_API_KEY
hermes config set model.provider regcloud
hermes config set model.default claude-5.5-sonnet      # id из GET /v1/models
hermes config set model.base_url https://ai.reg.cloud/v1
hermes -z "Ответь одним словом: работаешь?"             # smoke-test
```

**Telegram из РФ-сервера не работает** (`api.telegram.org` заблокирован) — для таких клиентов
основной канал = веб-интерфейс (§8), Telegram только с прокси/зарубежным сервером.

## 7. Автозапуск (systemd --user)

`~/.config/systemd/user/hermes-dashboard.service`:

```ini
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
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now hermes-dashboard
```

`MemoryMax` — страховка прода: при утечке ООМ-киллер убьёт агента, а не сайт. Эталон: ~170 МБ в простое.

## 8. Веб-интерфейс

### 8a. По умолчанию — SSH-туннель

Слушать только `127.0.0.1`, авторизация не нужна:

```bash
ssh -N -L 9119:127.0.0.1:9119 hermes-<client>   # → http://localhost:9119
```

### 8b. Свой домен через веб-сервер клиента

Нужны: A-запись `hermes.<домен>` → IP, доступ к конфигу reverse proxy клиента.

1. **Логин/пароль в Hermes** (обязателен при не-loopback bind). Хеш — stdlib scrypt, пароль на
   сервере не хранится:
   ```bash
   PW=$(python3 -c "import secrets;print(secrets.token_urlsafe(18))")
   HASH=$(printf %s "$PW" | python3 -c "import sys,hashlib,secrets,base64
   s=secrets.token_bytes(16);dk=hashlib.scrypt(sys.stdin.read().encode(),salt=s,n=2**14,r=8,p=1,dklen=32,maxmem=0)
   print('scrypt\$16384\$8\$1\$%s\$%s'%(base64.b64encode(s).decode(),base64.b64encode(dk).decode()))")
   # в ~/.hermes/.env:
   HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<user>
   HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$HASH
   HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(python3 -c "import secrets;print(secrets.token_hex(32))")
   HERMES_DASHBOARD_PUBLIC_URL=https://hermes.<домен>
   ```
2. **Где живёт proxy клиента** — определить без root:
   `cat /proc/$(pgrep -f 'caddy run\|nginx: master' | head -1)/cgroup` → `docker-<id>.scope` = в контейнере.
3. **Proxy в Docker-контейнере** (эталонный случай: Caddy встроен в образ сайта, конфиг в его репо):
   - в compose сервиса proxy: `extra_hosts: ["host.docker.internal:host-gateway"]` (= docker0, 172.17.0.1);
   - в конфиг: `hermes.<домен> { reverse_proxy host.docker.internal:9119 }`; проверить
     `docker run --rm -v ./Caddyfile:/etc/caddy/Caddyfile caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile`;
   - ufw (root): `ufw allow from <подсеть compose> to 172.17.0.1 port 9119 proto tcp` —
     иначе контейнер не достучится до хоста (INPUT deny);
   - Hermes: `--host 172.17.0.1` в unit-файле. Изменения в репо сайта — **только через PR клиента**,
     merge = деплой прода, его делает клиент.
4. **Proxy на хосте**: Hermes остаётся на `127.0.0.1`, в конфиг `reverse_proxy 127.0.0.1:9119`, ufw не трогаем.

## 9. Приёмка

- [ ] Health-check прода одинаковый до и после работ.
- [ ] `id hermes` — нет sudo/docker; `loginctl show-user hermes -p Linger` = yes.
- [ ] `hermes -z "..."` отвечает через выбранного провайдера.
- [ ] `systemctl --user is-active hermes-dashboard` = active; переживает `reboot` (проверить с клиентом в окно).
- [ ] `ss -ltn | grep 9119` — только 127.0.0.1 (или docker0 при 8b), снаружи `curl http://<IP>:9119` не отвечает.
- [ ] При 8b: без логина — страница входа; с логином — дашборд; сайт клиента открывается.
- [ ] `stat -c %a ~/.hermes/.env` = 600; ключи не попали в логи/историю.

## 10. Откат

```bash
# под hermes
systemctl --user disable --now hermes-dashboard; rm ~/.config/systemd/user/hermes-dashboard.service
hermes uninstall            # или rm -rf ~/.hermes ~/.local/bin/hermes*
# под root (если делали 8b)
ufw delete allow from <подсеть> to 172.17.0.1 port 9119 proto tcp   # + revert PR в репо клиента
loginctl disable-linger hermes; userdel -r hermes
```

## 11. Известные грабли

- **MTU 1450** — зависающие загрузки внутри контейнеров; для нативной установки обычно не влияет.
- **РФ-сервер**: блокируются `nodejs.org`, `api.telegram.org`, Cloudflare-CDN Nous → см. §5, §6.
- **Классификатор/политики агента-исполнителя** могут блокировать root-действия на проде —
  заранее согласуй с клиентом, кто выполняет §3 и §8b.3, и держи готовые команды для копипаста.
- **Мало RAM** — никаких локальных моделей и локального whisper; STT тоже через API
  (см. `scripts/vps/openrouter-stt.py`).

## 12. Шаблон отчёта клиенту

```
Готово: Hermes Agent на <IP>, пользователь hermes (без sudo/Docker).
Модель: <провайдер>/<модель>. Доступ: https://hermes.<домен> (логин <user>) | SSH-туннель.
Прод: health-check OK до/после. Изменения на сервере под root: <список или «нет»>.
Ресурсы: ~170 МБ RAM в простое, лимит 1.6 ГБ; ~1.5 ГБ диска.
Установщик: NousResearch install.sh, sha256 <...>, коммит Hermes <...>.
Откат: см. §10.
```
