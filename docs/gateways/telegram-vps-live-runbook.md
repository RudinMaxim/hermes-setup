# Telegram VPS live runbook

Временный рабочий план для подключения Telegram-группы на созвоне.

VPS:

```text
201.51.1.133
```

Бот:

```text
@loveworkoperation_bot
```

## Цель

Сделать так, чтобы Hermes мог писать сообщения в рабочую Telegram-группу, но
участники группы не управляли агентом и не получали ответы на обычные сообщения.

Рабочая схема:

- управление агентом только из лички владельца;
- рабочая группа используется как `home channel` для исходящих сообщений;
- бот не админ группы;
- Telegram privacy mode включен;
- в `TELEGRAM_ALLOWED_USERS` указан только numeric user ID владельца;
- в Hermes включен `telegram.require_mention: true`.

## Что подготовить до созвона

### 1. Зайти на VPS

```bash
ssh hermes@201.51.1.133
cd ~/hermes-setup
```

### 2. Проверить, что gateway запущен

```bash
./scripts/setup-gateway.sh --restart
docker exec hermes hermes gateway status
```

Ожидаемо: gateway активен, без ошибки токена.

### 3. Проверить `.env` без вывода токена

```bash
grep '^TELEGRAM_ALLOWED_USERS=' config/.env
grep -q '^TELEGRAM_BOT_TOKEN=.\+' config/.env && echo 'TELEGRAM_BOT_TOKEN is set'
```

Ожидаемо:

```text
TELEGRAM_ALLOWED_USERS=<твой numeric Telegram user ID>
TELEGRAM_BOT_TOKEN is set
```

В `TELEGRAM_ALLOWED_USERS` не добавлять группу, заказчика или участников.

### 4. Проверить, что Telegram gateway включен

```bash
grep -A3 '^\[telegram\]' config/gateways.toml
```

Ожидаемо:

```toml
[telegram]
enabled = true
```

### 5. Проверить BotFather privacy mode

В Telegram открыть `@BotFather`:

```text
/setprivacy
```

Выбрать `@loveworkoperation_bot` и поставить:

```text
Enable
```

Это нужно, чтобы бот в группе не видел обычную переписку.

### 6. Проверить Hermes group-safe режим

```bash
docker exec hermes sh -lc 'python3 - <<PY
import os, yaml
path = os.path.join(os.environ.get("HERMES_HOME", "/opt/data"), "config.yaml")
cfg = yaml.safe_load(open(path, encoding="utf-8")) or {}
print(cfg.get("telegram", {}))
PY'
```

Ожидаемо в выводе:

```text
'require_mention': True
```

Если этого нет:

```bash
./scripts/setup-hermes.sh
./scripts/setup-gateway.sh --restart
```

## Репетиция в тестовой группе

### 1. Добавить бота в тестовую группу

Не выдавать права администратора.

### 2. Назначить группу home channel

В группе отправить ровно так, с `/` в начале строки:

```text
/sethome@loveworkoperation_bot
```

Не использовать:

```text
/sethome;
@loveworkoperation_bot /sethome
```

Почему:

- `/sethome;` содержит лишнюю `;`, это может не распознаться как команда;
- `@loveworkoperation_bot /sethome` начинается с упоминания, а не с команды;
- в группе с privacy mode надежнее адресовать команду как `/sethome@botname`.

### 3. Проверить исходящую публикацию

В личке с ботом отправить:

```text
Отправь в home channel короткое сообщение: "Тест: Hermes подключен к рабочей группе как канал уведомлений."
```

Ожидаемо: сообщение появляется в тестовой группе.

### 4. Проверить, что участники не управляют ботом

В группе отправить обычный текст без упоминания:

```text
Проверка: обычное сообщение участника.
```

Ожидаемо: бот молчит.

## Если бот не видит `/sethome`

Идти строго по порядку.

### 1. Проверить формат команды

В группе отправить:

```text
/sethome@loveworkoperation_bot
```

Команда должна начинаться с `/`. Не ставить `@bot` перед командой.

### 2. Проверить, что пишет именно разрешенный владелец

На VPS:

```bash
grep '^TELEGRAM_ALLOWED_USERS=' config/.env
```

Если там не твой numeric user ID, исправить файл и перезапустить:

```bash
nano config/.env
./scripts/setup-gateway.sh --restart
```

### 3. Проверить, что bot token живой

Не выводить токен на экран:

```bash
TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' config/.env | cut -d= -f2-)"
curl -fsS "https://api.telegram.org/bot${TOKEN}/getMe"
```

Ожидаемо:

```text
"ok":true
```

### 4. Проверить, получает ли Telegram update

Сразу после отправки `/sethome@loveworkoperation_bot` в группе:

```bash
TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' config/.env | cut -d= -f2-)"
curl -fsS "https://api.telegram.org/bot${TOKEN}/getUpdates" | grep -E 'sethome|chat|from|message'
```

Если `sethome` есть в update, Telegram доставляет сообщение, проблема дальше в
Hermes/gateway/allowlist.

Если `sethome` нет:

- бот не добавлен в эту группу;
- команда отправлена не тем форматом;
- у бота webhook/long polling конфликтует с другим запущенным экземпляром;
- Telegram privacy mode или группа доставляет только правильно адресованные команды.

### 5. Проверить логи gateway

```bash
docker logs --tail=120 hermes
docker exec hermes hermes gateway status
```

Искать:

- ошибки Telegram token;
- сообщения про unauthorized user;
- ошибки gateway startup;
- конфликты polling/webhook.

### 6. Перезапустить gateway

```bash
./scripts/setup-gateway.sh --restart
```

После перезапуска повторить в группе:

```text
/sethome@loveworkoperation_bot
```

## Если бот не отвечает на голосовые

### Журнал диагностики голосового ввода

Контекст: на VPS текстовые сообщения в Telegram работают, но voice messages не
дают ответа. Значит базовый Telegram gateway, bot token и allowlist в целом
живые; проблема находится в voice/STT path.

Что выяснили:

- `docker exec hermes hermes gateway status` показал, что gateway запущен.
- `ffmpeg` в контейнере есть:

```text
/usr/bin/ffmpeg
ffmpeg version 6.1.1-3ubuntu5
```

- Изначально `whisper` отсутствовал в контейнере:

```bash
docker exec hermes sh -lc 'command -v whisper || true'
```

Вывод был пустой.

- Узкий лог-фильтр после voice message ничего не показал:

```bash
docker logs --since 2m hermes 2>&1 | grep -Ei 'telegram|voice|audio|file|transcrib|whisper|ffmpeg|unauthorized|error'
```

Это не доказывает отсутствие update: gateway может молча игнорировать
неподдерживаемый voice path.

- `getUpdates` без нового сообщения после остановки gateway тоже не дал
полезного результата. Этот тест корректен только если сначала остановить
gateway, затем отправить новое уникальное сообщение, и только потом читать
`getUpdates`.

- В логах gateway отдельно всплывала ошибка Playwright MCP:

```text
MCP server 'playwright' initial connection failed
```

Это может тормозить старт gateway, но не является корневой причиной voice:
текстовые сообщения после этого отвечали.

Что пробовали:

1. Перезапускали gateway:

```bash
./scripts/setup-gateway.sh --restart
```

2. Проверяли наличие аудиоконвертера:

```bash
docker exec hermes sh -lc 'command -v ffmpeg && ffmpeg -version | head -n 1'
```

3. Проверяли наличие STT backend:

```bash
docker exec hermes sh -lc 'command -v whisper || true'
```

4. Установили `openai-whisper` в отдельный venv внутри volume:

```bash
docker exec -u root hermes bash -lc '
set -e
apt-get update
apt-get install -y python3-venv
python3 -m venv /opt/data/venvs/whisper
/opt/data/venvs/whisper/bin/pip install -U pip setuptools wheel
/opt/data/venvs/whisper/bin/pip install -U openai-whisper
ln -sf /opt/data/venvs/whisper/bin/whisper /usr/local/bin/whisper
'
```

Результат: установка прошла, `whisper` появился в PATH.

5. Скачали модель `base` и проверили Whisper на тестовом WAV:

```bash
docker exec hermes bash -lc 'mkdir -p /opt/data/tmp && ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 1 /opt/data/tmp/silence.wav && whisper /opt/data/tmp/silence.wav --model base --language ru --output_dir /opt/data/tmp --output_format txt'
```

Результат: модель `base` скачалась, Whisper запустился. Предупреждение
`FP16 is not supported on CPU; using FP32 instead` ожидаемо на CPU.

6. Первая попытка записать `stt` config через heredoc не сработала из-за
отступов перед Python-кодом:

```text
IndentationError: unexpected indent
```

Правильная команда без heredoc:

```bash
docker exec hermes python3 -c 'import os,yaml; from pathlib import Path; p=Path(os.environ.get("HERMES_HOME","/opt/data"))/"config.yaml"; c=yaml.safe_load(p.read_text(encoding="utf-8")) or {}; s=c.get("stt") or {}; l=s.get("local") or {}; l.update({"model":"base","language":"ru"}); s.update({"enabled":True,"provider":"local_command","local":l}); c["stt"]=s; p.write_text(yaml.safe_dump(c,sort_keys=False,allow_unicode=True),encoding="utf-8")'
docker restart hermes
sleep 10
docker exec hermes python3 -c 'import os,yaml; from pathlib import Path; p=Path(os.environ.get("HERMES_HOME","/opt/data"))/"config.yaml"; c=yaml.safe_load(p.read_text()) or {}; print(c.get("stt"))'
```

Ожидаемый вывод:

```text
{'enabled': True, 'provider': 'local_command', 'local': {'model': 'base', 'language': 'ru'}}
```

Текущий вывод по состоянию установки:

```text
/usr/local/bin/whisper
usage: whisper [-h] [--model MODEL] [--model_dir MODEL_DIR] [--device DEVICE]
```

Что осталось проверить:

1. Убедиться, что `stt` config реально записан в `/opt/data/config.yaml`.
2. Отправить voice message в личку боту, не в группу.
3. Сразу посмотреть широкие логи:

```bash
docker logs --since 3m hermes 2>&1 | tail -n 200
```

4. Если текст отвечает, а voice все равно молчит при наличии `stt` config и
`whisper`, значит текущий Hermes Telegram gateway может не поддерживать voice
messages на этом VPS-сборке или ожидает другой STT provider config. Тогда voice
не включать в live demo и отдельно проверять возможности Hermes версии.

Важно:

- Голосовые в группе не использовать для проверки: при включенном privacy mode
  бот может их вообще не получать.
- Не запускать `./scripts/setup-gateway.sh --restart` без необходимости после
  ручной установки `whisper`: пересоздание контейнера может убрать symlink
  `/usr/local/bin/whisper`, хотя venv в `/opt/data/venvs/whisper` сохранится.
- Bot token был засвечен в терминальном выводе. Перед демонстрацией лучше
  перевыпустить token через `@BotFather`, обновить `config/.env` и перезапустить
  gateway.

Сначала разделить два случая.

### Текущий статус на VPS

Первичная проверка на `201.51.1.133` показала:

```text
Gateway is running
ffmpeg: /usr/bin/ffmpeg
whisper: отсутствует в PATH
```

После ручной установки `openai-whisper`:

```text
whisper: /usr/local/bin/whisper
model base: скачана
```

Вывод: Telegram gateway живой, аудиоконвертер есть, Whisper установлен вручную,
но нужно отдельно подтвердить, что `stt` config записан и gateway реально
использует voice/STT path.

### Решение: STT через OpenRouter (автоматизировано)

Корневая причина плохого распознавания: модель whisper `base` слишком слаба для
живой русской речи через сжатый Telegram Opus — расшифровка искажается, и агент
отвечает на мусор. Локальный `medium`/`large`, который дал бы хорошее качество,
не помещается в 3 GB RAM этого VPS.

Решение — увести STT в OpenRouter тем же `OPENROUTER_API_KEY`, что уже есть в
контейнере. У OpenRouter нет отдельного `/audio/transcriptions`: аудио шлётся как
`input_audio` (base64) в `/chat/completions` к аудио-модели (по умолчанию
`google/gemini-2.5-flash`, переопределяется `HERMES_OPENROUTER_STT_MODEL`).

Реализовано drop-in обёрткой с CLI-интерфейсом whisper — `scripts/vps/openrouter-stt.py`.
Hermes (`stt.provider = local_command`) вызывает бинарь `whisper`, а внутри идёт
запрос в OpenRouter. Конфиг hermes менять не нужно.

Это **самолечится при каждом `setup-gateway.sh` и `--restart`** через
`scripts/lib/voice.sh` (`ensure_voice_stt`):

- деплоит обёртку в `/opt/data/bin/openrouter-stt.py` (переживает пересоздание
  контейнера);
- чинит symlink `/usr/local/bin/whisper` → обёртка (он слетает при пересоздании);
- включает `stt` config (`enabled`, `provider=local_command`, `language=ru`);
- если нет `OPENROUTER_API_KEY` или `ffmpeg` — пишет `[WARN]`, но не роняет
  текстовый gateway.

Идемпотентно: повторный прогон даёт только `[SKIP]`.

Явная проверка готовности (структурные проверки + живой пинг OpenRouter, не
зашита в setup, чтобы не делать платный вызов на каждом прогоне):

```bash
make check-voice
# или: bash scripts/vps/check-voice.sh
```

End-to-end проверка: отправить голосовое в личку боту и посмотреть расшифровку:

```bash
docker logs --since 3m hermes 2>&1 | grep -iEA2 'transcri|whisper|voice|stt'
```

## Если бот перестал отвечать после одного ответа

Это важнее voice: сначала проверить базовую доставку текстовых сообщений.

### 0. Если token засветился в терминале или переписке

Если строка `TELEGRAM_BOT_TOKEN` или значение token попали в общий чат, запись
экрана или лог, token считать скомпрометированным.

Перед созвоном перевыпустить token в `@BotFather`, обновить `config/.env` и
перезапустить gateway:

```bash
nano config/.env
./scripts/setup-gateway.sh --restart
```

### 1. Проверить, что bot token принадлежит нужному боту

```bash
TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' config/.env | cut -d= -f2-)"
curl -fsS "https://api.telegram.org/bot${TOKEN}/getMe"
```

Ожидаемо в JSON:

```text
"ok":true
"username":"loveworkoperation_bot"
```

### 2. Проверить webhook конфликт

```bash
curl -fsS "https://api.telegram.org/bot${TOKEN}/getWebhookInfo"
```

Ожидаемо для polling gateway:

```text
"url":""
```

Если `url` не пустой, long polling gateway может не получать сообщения. Тогда:

```bash
curl -fsS "https://api.telegram.org/bot${TOKEN}/deleteWebhook?drop_pending_updates=false"
./scripts/setup-gateway.sh --restart
```

### 3. Проверить raw update правильно

Важно: старые сообщения могли уже быть забраны gateway. Поэтому проверка
делается только на новом сообщении, отправленном после остановки gateway.

1. Остановить gateway:

```bash
docker stop hermes
```

2. В личке с ботом отправить новый уникальный текст:

```text
RAW_TEST_1617
```

3. Сразу проверить updates без `grep`:

```bash
curl -fsS "https://api.telegram.org/bot${TOKEN}/getUpdates?timeout=0" | python3 -m json.tool
```

Интерпретация:

- если видно `RAW_TEST_1617`, Telegram доставляет сообщения этому bot token;
- если `result: []`, сообщение не пришло к этому token: не тот бот, не тот чат,
  сообщение отправлено до остановки gateway, бот заблокирован или updates
  забирает другой процесс.

4. Вернуть gateway:

```bash
./scripts/setup-gateway.sh --restart
```

### 4. Если raw update есть, но Hermes не отвечает

После рестарта отправить в личку:

```text
ping
```

Потом смотреть широкие логи без узкого фильтра:

```bash
docker logs --since 5m hermes 2>&1 | tail -n 240
```

Искать:

- `unauthorized user` — user ID отправителя не входит в
  `TELEGRAM_ALLOWED_USERS`;
- `Provider returned error` — Telegram получил сообщение, но LLM provider не
  ответил;
- ошибки `rate limit`, `401`, `403`, `model`, `openrouter`;
- traceback gateway.

Проверить allowlist:

```bash
grep '^TELEGRAM_ALLOWED_USERS=' config/.env
```

Если сообщение пишет не один из этих numeric user ID, Hermes может молча
игнорировать входящее сообщение.

### Случай A: голосовое отправлено в группе

При включенном Telegram privacy mode бот в группе не получает обычные сообщения.
Голосовое сообщение не может начинаться с `/command@botname`, поэтому обычное
voice message в группе, скорее всего, вообще не дойдет до gateway.

Это ожидаемо для безопасной схемы созвона:

- группа — только канал публикации;
- управление — только в личке владельца;
- участники группы не управляют ботом.

Для демонстрации не использовать voice message в группе как команду. Если нужен
голосовой ввод, отправлять голосовое в личный чат с ботом.

### Случай B: голосовое отправлено в личку владельцем

Если voice message в личке не обрабатывается, проверить по слоям.

#### 1. Проверить, отвечает ли бот на обычный текст в личке

В личке с ботом отправить:

```text
ping
```

Если на текст нет ответа, это не voice-проблема. Проверять gateway, token,
allowlist и модель.

#### 2. Проверить gateway на VPS

```bash
ssh hermes@201.51.1.133
cd ~/hermes-setup
docker exec hermes hermes gateway status
docker logs --tail=160 hermes
```

Искать в логах:

- ошибки Telegram token;
- `unauthorized user`;
- ошибки загрузки файла;
- ошибки `ffmpeg`, `whisper`, `transcription`, `audio`, `voice`;
- ошибки модели после распознавания.

#### 3. Проверить, что контейнер умеет работать с аудио

```bash
docker exec hermes sh -lc 'command -v ffmpeg && ffmpeg -version | head -n 1'
docker exec hermes sh -lc 'command -v whisper || true'
docker exec hermes sh -lc 'python3 - <<PY
mods = ["whisper", "openai", "pydub"]
for mod in mods:
    try:
        __import__(mod)
        print(mod + ": ok")
    except Exception as exc:
        print(mod + ": missing: " + exc.__class__.__name__)
PY'
```

Интерпретация:

- `ffmpeg` нужен для конвертации Telegram OGG/Opus;
- `whisper` или другой STT backend нужен для распознавания речи;
- если STT backend отсутствует, Hermes может получать voice update, но не иметь
  чем превратить его в текст.

#### 4. Проверить Hermes config на voice/STT

```bash
docker exec hermes sh -lc 'python3 - <<PY
import os, yaml
path = os.path.join(os.environ.get("HERMES_HOME", "/opt/data"), "config.yaml")
cfg = yaml.safe_load(open(path, encoding="utf-8")) or {}
for key in ("voice", "speech", "audio", "stt", "telegram"):
    if key in cfg:
        print(key, "=", cfg[key])
PY'
```

Если в конфиге нет `voice`/`stt`-настроек, это признак, что текущий VPS-контур
настроен как текстовый Telegram gateway, а не как voice gateway.

#### 5. Проверить, доходит ли voice update до Telegram gateway

Не запускать `getUpdates` одновременно с работающим gateway без необходимости:
это может конфликтовать с long polling. Сначала смотреть логи:

```bash
docker logs --since 10m hermes | grep -Ei 'voice|audio|file|telegram|error|unauthorized|transcrib|whisper|ffmpeg'
```

Если в логах нет вообще ничего после отправки голосового в личку:

- голосовое отправлено не владельцем из `TELEGRAM_ALLOWED_USERS`;
- gateway не запущен или смотрит другой bot token;
- update забирает другой экземпляр бота.

Если в логах есть voice/file, но дальше ошибка STT:

- это уже не Telegram-настройка, а отсутствующий или сломанный speech-to-text
  backend на VPS.

#### 6. Если лог после voice полностью пустой

Пустой вывод такой команды:

```bash
docker logs --since 2m hermes 2>&1 | grep -Ei 'telegram|voice|audio|file|transcrib|whisper|ffmpeg|unauthorized|error'
```

не доказывает, что Telegram update не пришел: gateway может молча игнорировать
неподдерживаемый тип сообщения. Нужно сравнить voice и text в одном и том же
чате.

1. В тот же чат, куда отправлялось голосовое, отправить обычный текст:

```text
ping
```

2. Проверить широкие логи без узкого `grep`:

```bash
docker logs --since 2m hermes 2>&1 | tail -n 120
```

Если текст в этом же чате тоже не дает ответа, проблема не в voice: проверять
`TELEGRAM_ALLOWED_USERS`, token и сам gateway.

Если текст отвечает, а voice молча игнорируется, следующий минимальный тест —
посмотреть сырой Telegram update без работающего polling gateway.

3. Остановить gateway-контейнер на короткое окно:

```bash
docker stop hermes
```

4. Отправить голосовое в личку боту.

5. Посмотреть, есть ли `voice` в raw Telegram update:

```bash
TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' config/.env | cut -d= -f2-)"
curl -fsS "https://api.telegram.org/bot${TOKEN}/getUpdates" | grep -E '"voice"|"message"|"from"|"chat"'
```

6. Вернуть gateway:

```bash
./scripts/setup-gateway.sh --restart
```

Интерпретация:

- `voice` есть в raw update: Telegram доставляет голосовое, но Hermes gateway
  его игнорирует или не умеет распознать без STT backend.
- `voice` нет в raw update: голосовое отправлено не туда, не тем аккаунтом,
  update уже забран другим процессом или бот не получает этот тип сообщений.

### Вывод для созвона

Для созвона не завязываться на голосовые в рабочей группе. Демонстрационный
сценарий должен быть текстовым:

1. `/sethome@loveworkoperation_bot` в группе.
2. Команда в личке владельца текстом.
3. Исходящее сообщение появляется в группе.
4. Обычные сообщения участников в группе игнорируются.

Voice можно отдельно проверять в личке после созвона. Если voice нужен как
обязательная функция, его надо тестировать заранее на VPS как отдельный
мультимедийный контур, а не включать в live demo.

## Сценарий на созвоне

### Что сказать заказчику

```text
Я подключаю бота не как участника переписки, а как канал публикации апдейтов.
Обычные сообщения группы он читать и обрабатывать не будет. Управление остается
только у меня через личный чат.
```

### Действия

1. Добавить `@loveworkoperation_bot` в рабочую группу.
2. Не выдавать права администратора.
3. Отправить в группе:

```text
/sethome@loveworkoperation_bot
```

4. В личке с ботом отправить:

```text
Отправь в home channel короткое сообщение: "Hermes подключен к рабочей группе как канал уведомлений."
```

5. Попросить участника написать обычное сообщение без упоминания бота.
6. Убедиться, что бот молчит.

## Что не делать на демонстрации

- Не показывать `config/.env`.
- Не показывать token из BotFather.
- Не отключать privacy mode.
- Не делать бота админом группы.
- Не добавлять участников в `TELEGRAM_ALLOWED_USERS`.
- Не тестировать управление ботом от аккаунта заказчика.

## Быстрый откат

Самый быстрый откат прямо на созвоне:

1. Удалить бота из группы.
2. Если нужно отключить gateway на VPS:

```bash
ssh hermes@201.51.1.133
cd ~/hermes-setup
nano config/gateways.toml
```

Поставить:

```toml
[telegram]
enabled = false
```

Применить:

```bash
./scripts/setup-gateway.sh
```
