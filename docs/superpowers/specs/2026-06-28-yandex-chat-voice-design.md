# YandexGPT и SpeechKit для Hermes — технический дизайн

**Статус:** approved (brainstorming complete)

**Дата:** 2026-06-28

**Scope:** текстовый чат и Telegram voice на VPS

## Цель

Убрать обязательную зависимость текстового чата и распознавания Telegram voice
от OpenRouter. Основной LLM должен работать через YandexGPT, а голосовые
сообщения любой обычной для Telegram длительности, включая сообщения длиннее
30 секунд, — через асинхронный Yandex SpeechKit API v3.

Миграция не должна изменять Docker volume `hermes_data`, Telegram bot token,
allowlist, SOUL, sessions, state database или MCP-конфигурацию.

## Не цели

- Генерация изображений и видео.
- TTS: Hermes продолжает отвечать текстом.
- Перенос или преобразование истории и памяти Hermes.
- LiteLLM, второй LLM-провайдер или автоматический межпровайдерный fallback.
- Object Storage для voice-файлов.
- Изменения macOS multimedia-контура.

## Выбранный подход

### Чат

Hermes использует штатный custom provider:

```text
Hermes -> https://ai.api.cloud.yandex.net/v1 -> YandexGPT
```

Endpoint совместим с OpenAI Chat Completions и поддерживает function calling.
В конфигурации используется именованный provider `custom:yandex`, ключ берётся
из `YANDEX_API_KEY`, а модель задаётся полным URI
`gpt://<folder-id>/yandexgpt`. Полный URI позволяет однозначно указать каталог,
в котором оплачивается inference.

Имя модели остаётся конфигурируемым через `HERMES_MODEL`. Во время настройки
оно проверяется запросом к `/v1/models`; установщик не должен молча заменять
его на OpenRouter default.

### Голос

Сохраняется существующий контракт Hermes `stt.provider=local_command`:

```text
Telegram OggOpus
  -> Hermes вызывает whisper-compatible CLI
  -> yandex-speechkit-stt.py
  -> SpeechKit recognizeFileAsync
  -> polling operation
  -> getRecognition
  -> transcript.txt + stdout
  -> Hermes передаёт текст в YandexGPT
```

Новый адаптер заменяет только реализацию CLI. Он принимает те же аргументы,
которые сейчас принимает `openrouter-stt.py`, поэтому изменения внутри Hermes
не требуются.

Аудио OggOpus отправляется напрямую как base64 в поле `content`; обязательного
бакета нет. Используется модель `general`, язык `ru-RU` и включённая
нормализация текста. Приложение не вводит искусственный лимит 30 секунд.

Для первого production smoke-test используется voice длительностью не менее 90
секунд. Предельные размеры inline-запроса дополнительно проверяются живым
тестом с VPS; при превышении транспортного лимита адаптер возвращает явную
ошибку с размером файла, а не пустую расшифровку.

## Почему не другие варианты

### Object Storage

Подходит для многочасовых и очень больших файлов, но добавляет бакет,
storage credentials, загрузку, lifecycle policy и удаление временных объектов.
Для Telegram voice это лишняя инфраструктура, поскольку SpeechKit v3 принимает
inline `content`.

### Разрезание на фрагменты до 30 секунд

Позволяет использовать синхронный STT, но ухудшает пунктуацию и распознавание
на границах фраз, усложняет склейку и делает больше API-запросов. Этот вариант
не используется.

## Конфигурация и доступы

Один сервисный аккаунт получает минимальные роли:

- `ai.languageModels.user`;
- `ai.speechkit-stt.user`.

API-ключ ограничивается областью `yc.ai.foundationModels.execute`, которая
разрешает обращения к AI Studio и SpeechKit. В `config/.env` добавляются:

```dotenv
YANDEX_API_KEY=
YANDEX_FOLDER_ID=
HERMES_MODEL_PROVIDER=custom:yandex
HERMES_MODEL=gpt://<folder-id>/yandexgpt
HERMES_STT_PROVIDER=yandex
HERMES_YANDEX_STT_MODEL=general
HERMES_YANDEX_STT_TIMEOUT=600
```

`YANDEX_API_KEY` никогда не записывается в `config.yaml`, логи, тестовые
fixtures или git. `config.yaml` содержит только `key_env: YANDEX_API_KEY`.

## Изменения компонентов

### `scripts/setup-hermes.sh`

- Считать `YANDEX_API_KEY` допустимым LLM credential.
- Для `custom:yandex` записывать именованный custom provider с Yandex base URL,
  `key_env` и `api_mode: chat_completions`.
- Сохранять выбранную модель и custom provider при повторных запусках.
- Не требовать `OPENROUTER_API_KEY`, если Yandex настроен.

### `config/.env.example`

- Добавить Yandex variables и безопасные значения по умолчанию.
- Явно разделить обязательные chat/voice credentials и необязательные
  OpenRouter media credentials.

### `scripts/vps/yandex-speechkit-stt.py`

- Сохранить whisper-compatible разбор аргументов и формат выходного файла.
- Принимать OggOpus без перекодирования; WAV/MP3 указывать соответствующим
  `containerAudioType`.
- Создать async recognition operation.
- Опросить статус с exponential backoff и общим timeout.
- Получить и объединить только финальные фрагменты распознавания в исходном
  порядке.
- Атомарно записать `<output_dir>/<stem>.txt` и продублировать текст в stdout.
- Не печатать API-ключ или полное тело аудиозапроса.

### `scripts/lib/voice.sh`

- Выбирать STT backend по `HERMES_STT_PROVIDER`.
- Разворачивать Yandex shim в `/opt/data/bin` и восстанавливать symlink
  `/usr/local/bin/whisper` после пересоздания контейнера.
- Проверять `YANDEX_API_KEY` и `YANDEX_FOLDER_ID` для Yandex backend.
- Сохранить идемпотентность: второй setup без изменений выдаёт `[SKIP]`.

### `scripts/vps/check-voice.sh`

- Проверять фактически выбранный backend и его переменные.
- Выполнять дешёвую проверку аутентификации без отправки пользовательского
  аудио.
- Оставить end-to-end voice smoke-test ручным, чтобы обычный setup не создавал
  платные STT-запросы.

Существующий OpenRouter shim можно сохранить на время rollout как явный
rollback backend, но он не должен требоваться для Yandex-конфигурации.

## Обработка ошибок

- `401/403`: немедленная ошибка с указанием проверить ключ, scope и роли.
- `429` и `5xx`: ограниченные повторы с exponential backoff и jitter.
- Незавершённая операция: ожидание до `HERMES_YANDEX_STT_TIMEOUT`, затем
  контролируемый timeout.
- Пустой или неожиданный ответ: ошибка; пустой `.txt` не создаётся.
- Неподдерживаемый контейнер аудио: явная ошибка с перечнем OggOpus/WAV/MP3.
- Временный файл результата создаётся рядом с целевым и переименовывается
  только после успешного завершения.
- Ошибка STT не останавливает Telegram gateway и не повреждает последующие
  текстовые сообщения.

## Тестирование

### Автоматические тесты

1. Unit-тесты STT adapter с mock HTTP:
   - whisper CLI arguments;
   - OggOpus payload;
   - async operation polling;
   - сборка финального текста;
   - `401`, `429`, `5xx`, timeout и malformed response;
   - отсутствие секрета в stderr.
2. Bats-тесты setup:
   - Yandex credentials принимаются без OpenRouter;
   - custom provider записывается корректно;
   - повторный запуск идемпотентен;
   - voice symlink восстанавливается после recreate;
   - отсутствующий Yandex credential даёт понятный warning, а не ломает чат.

### Живые smoke-тесты с VPS

1. Обычный текстовый ответ YandexGPT.
2. Function call через Hermes tool.
3. Короткий Telegram voice.
4. Telegram voice длительностью не менее 90 секунд.
5. Перезапуск контейнера и повторение текстового и голосового теста.
6. Запуск при отсутствующем `OPENROUTER_API_KEY`.

Живые тесты не входят в CI и запускаются только при явно заданном
`YANDEX_API_KEY`.

## Rollout и rollback

1. Скопировать `config/.env` и `/opt/data/config.yaml` в backup-файлы.
2. Добавить Yandex credentials, не удаляя старые credentials.
3. Проверить Yandex API напрямую.
4. Переключить чат и выполнить text/tool smoke-tests.
5. Переключить STT и выполнить short/90-second voice smoke-tests.
6. Пересоздать контейнер и проверить self-healing.
7. После стабильной проверки удалить обязательность OpenRouter из рабочей
   конфигурации.

Rollback выполняется восстановлением backup `config.yaml`, значения
`HERMES_MODEL_PROVIDER` и предыдущего `HERMES_STT_PROVIDER`. Docker volume с
данными не заменяется и не удаляется.

## Критерии готовности

- Hermes запускается без `OPENROUTER_API_KEY`.
- Текстовый Telegram chat отвечает через YandexGPT.
- Hermes успешно выполняет минимум один tool call через YandexGPT.
- Voice OggOpus длительностью более 30 секунд распознаётся SpeechKit и
  передаётся в тот же диалог.
- После пересоздания контейнера chat и voice остаются настроенными.
- API-ключ отсутствует в git diff и логах.
- Ошибка SpeechKit не останавливает обработку текстовых сообщений.
- Повторный setup не изменяет уже корректную конфигурацию.

## Источники

- [Hermes: custom OpenAI-compatible providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- [Yandex AI Studio: быстрый старт OpenAI-compatible API](https://aistudio.yandex.ru/docs/ru/ai-studio/quickstart/)
- [YandexGPT: function calling](https://aistudio.yandex.ru/docs/ru/ai-studio/operations/generation/completions-function.html)
- [SpeechKit v3: AsyncRecognizer.RecognizeFile](https://aistudio.yandex.ru/docs/ru/speechkit/stt-v3/api-ref/AsyncRecognizer/recognizeFile)
- [SpeechKit v3: AsyncRecognizer.GetRecognition](https://aistudio.yandex.ru/docs/ru/speechkit/stt-v3/api-ref/AsyncRecognizer/getRecognition)
- [Yandex Cloud: API-ключи и scopes](https://yandex.cloud/ru/docs/iam/concepts/authorization/api-key)
