# Identity и память Hermes

Hermes собирает поведение из независимых слоёв:

| Слой | Назначение | Где хранится |
|---|---|---|
| Identity | Кто ассистент и как говорит | `~/.hermes/SOUL.md` |
| User profile | Кто пользователь и что предпочитает | `~/.hermes/memories/USER.md` |
| Durable memory | Среда и устойчивые договорённости | `~/.hermes/memories/MEMORY.md` |
| Procedures | Повторяемые рабочие процессы | `~/.hermes/skills/` |
| Project rules | Правила конкретного репозитория | `.hermes.md` или `AGENTS.md` |
| Temporary mode | Режим текущей сессии | `/personality` |

Не дублируй одну инструкцию в нескольких слоях. Дублирование увеличивает
system prompt и создаёт конфликты при обновлении.

## Рабочий цикл

1. Заполни [questionnaire.md](questionnaire.md).
2. Скопируй `config/agent-profile.yaml.example` в
   `config/agent-profile.yaml`.
3. Перенеси устойчивые ответы в YAML.
4. Покажи preview:

```bash
"$HOME/.hermes/hermes-agent/venv/bin/python" \
  scripts/macos/render-agent-identity.py \
  --profile config/agent-profile.yaml
```

5. Проверь SOUL, USER и MEMORY.
6. Примени профиль:

```bash
"$HOME/.hermes/hermes-agent/venv/bin/python" \
  scripts/macos/render-agent-identity.py \
  --profile config/agent-profile.yaml \
  --hermes-home "$HOME/.hermes" \
  --apply
```

Скрипт проверяет лимиты встроенной памяти Hermes и сохраняет предыдущие версии
в `~/.hermes/backups/identity/<timestamp>/`.

## Управление памятью

Для личной или клиентской установки рекомендуется включить approval:

```text
/memory approval on
/skills approval on
```

Тогда автоматические выводы агента не попадут сразу в постоянный профиль:

```text
/memory pending
/memory approve <id>
/memory reject <id>
```

После изменения файлов начни новую сессию или перезапусти gateway. MEMORY и
USER загружаются как snapshot при создании сессии.

## Personality overlay

`/personality` является временной надстройкой над `SOUL.md`. Для проверки
базовой личности используй:

```text
/personality none
```

Не делай временный personality постоянным способом настройки клиента.

## Ревью

- SOUL: пересматривать после заметных проблем со стилем, а не каждую неделю.
- USER: проверять после изменения ролей, целей или предпочтений.
- MEMORY: ежемесячно удалять устаревшие технические факты.
- Skills: версионировать и тестировать как код.
- Клиентские профили: утверждать владельцем данных перед применением.
