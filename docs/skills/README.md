# Hermes Skills

`scripts/setup-skills.sh` синхронизирует skills, описанные в
`config/skills.toml`.

## Типы skills

- `builtin` — навык уже есть внутри Hermes; скрипт только запускает известную
  стабилизацию или проверку.
- `local` — навык лежит в этом репозитории и копируется в Hermes data volume.

Внешние источники GitHub, npm, URL и marketplace в v1 не поддерживаются.

## Локальные skills

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
