# Hermes Skills

`scripts/setup-skills.sh` синхронизирует skills, описанные в
`config/skills.toml`.

## Типы skills

- `builtin` — навык уже есть внутри Hermes; скрипт только запускает известную
  стабилизацию или проверку.
- `local` — навык лежит в этом репозитории и копируется в Hermes data volume.

Внешние источники GitHub, npm, URL и marketplace в v1 не поддерживаются.

## Локальные skills

Самый простой путь — создать skill helper-скриптом:

```bash
./scripts/add-skill.sh my_skill "Короткое описание навыка"
```

Команда:

- создаёт `skills/my_skill/SKILL.md`, если файла ещё нет;
- добавляет enabled-секцию `[my_skill]` в `config/skills.toml`, если её ещё нет;
- запускает `scripts/setup-skills.sh`, чтобы перенести skill в Hermes data
  volume.

Если `SKILL.md` уже существует, скрипт не перезаписывает его.

Локальный навык должен лежать в директории:

```text
skills/<name>/SKILL.md
```

Пример:

```toml
[project_memory]
enabled = true
type = "local"
source = "skills/project_memory"
description = "Project-specific workflow and memory skill"
```

Повторный запуск `setup-skills.sh` ничего не переписывает, если содержимое уже
совпадает. Если установленный навык отличается, старая версия сохраняется в:

```text
<HERMES_HOME>/backups/skills/<name>/<timestamp>/
```

`enabled = false` означает "не устанавливать и не обновлять". Скрипт не удаляет
уже установленный навык автоматически.

## Рабочий цикл

### 1. Создать skill

```bash
./scripts/add-skill.sh project-docs-telegram "Ведёт проектные документы и Telegram-апдейты"
```

После этого редактируй файл на host:

```bash
nano skills/project-docs-telegram/SKILL.md
```

Не редактируй копию внутри контейнера напрямую: следующий `setup-skills.sh`
перезапишет её из репозитория.

### 2. Перенести skill в контейнер

```bash
./scripts/setup-skills.sh
```

Скрипт копирует локальный каталог:

```text
skills/<name>/
```

в Hermes data dir внутри контейнера:

```text
/opt/data/skills/<name>/
```

Если контейнер использует другой `HERMES_HOME`, скрипт берёт его из
`docker exec hermes printenv HERMES_HOME`.

### 3. Проверить, что skill установлен

Проверить список:

```bash
docker exec hermes ls -la /opt/data/skills
```

Проверить конкретный файл:

```bash
docker exec hermes sed -n '1,120p' /opt/data/skills/project-docs-telegram/SKILL.md
```

Проверить весь файл:

```bash
docker exec hermes cat /opt/data/skills/project-docs-telegram/SKILL.md
```

### 4. Обновить skill

1. Отредактируй host-файл:

```bash
nano skills/project-docs-telegram/SKILL.md
```

2. Перенеси изменения в контейнер:

```bash
./scripts/setup-skills.sh
```

3. Проверь контейнерную копию:

```bash
docker exec hermes sed -n '1,80p' /opt/data/skills/project-docs-telegram/SKILL.md
```

Если содержимое не менялось, скрипт напечатает:

```text
[SKIP] skill.<name>: already up to date
```

Если содержимое изменилось, скрипт сделает backup старой версии и установит
новую:

```text
[OK] installed skill.<name>
```

### 5. Найти backup старой версии

Старые версии сохраняются внутри контейнера:

```text
/opt/data/backups/skills/<name>/<timestamp>/
```

Посмотреть backups:

```bash
docker exec hermes find /opt/data/backups/skills/project-docs-telegram -maxdepth 2 -type f -name SKILL.md
```

Посмотреть конкретную старую версию:

```bash
docker exec hermes sed -n '1,120p' /opt/data/backups/skills/project-docs-telegram/<timestamp>/SKILL.md
```

### 6. Отключить автообновление skill

В `config/skills.toml`:

```toml
[project-docs-telegram]
enabled = false
type = "local"
source = "skills/project-docs-telegram"
description = "..."
```

После этого:

```bash
./scripts/setup-skills.sh
```

`enabled = false` не удаляет уже установленный skill из контейнера. Он только
запрещает установку и обновление из репозитория.

### 7. Типовые ошибки

Если команда пишет:

```text
missing SKILL.md
```

значит в `source = "skills/<name>"` нет файла `SKILL.md`.

Если skill не обновился, проверь, что ты редактировал именно host-файл:

```text
skills/<name>/SKILL.md
```

а не контейнерную копию:

```text
/opt/data/skills/<name>/SKILL.md
```

Если Telegram gateway перезапустился во время `setup-skills.sh`, это ожидаемо
для встроенного `google_workspace`: его стабилизатор пересоздаёт gateway, чтобы
Telegram видел актуальный Google Workspace token.

## Google Workspace

`google_workspace` — built-in skill для стабильного доступа к Google Drive/Docs
через Telegram gateway.

```toml
[google_workspace]
enabled = true
type = "builtin"
stabilize = true
```

Когда `stabilize = true`, `setup-skills.sh` запускает
`scripts/stabilize-google-workspace.sh`. Если OAuth ещё не выполнен через Hermes
CLI, скрипт напечатает предупреждение и не будет ломать весь setup.

## Native macOS

`setup-macos.sh` устанавливает enabled local skills из `config/skills.toml`
или, если локального файла нет, из `config/skills.toml.example` в:

```text
~/.hermes/skills/<name>/
```

Установщик идемпотентен и сохраняет заменённую версию в
`~/.hermes/backups/skills/<name>/<timestamp>/`.

`obsidian_para` включён по умолчанию. Skill `obsidian-para` организует vault по
PARA и требует использовать scoped MCP `obsidian`, не прямые file tools.
