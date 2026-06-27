# Альтернативы OpenRouter для Hermes

Дата исследования: 25 июня 2026 года. Решение обновлено 28 июня 2026 года.

## Принятое решение: Plan A

Для текущей задачи выбран Yandex Cloud:

- основной чат: YandexGPT через OpenAI-совместимый API Yandex AI Studio;
- распознавание Telegram voice: Yandex SpeechKit API v3;
- изображения, видео, TTS и остальные мультимедийные функции не входят в эту
  миграцию;
- история, SOUL, sessions, Telegram gateway и MCP остаются в существующем
  Docker volume `hermes_data`.

Это не перенос данных. Меняются только два внешних маршрута: LLM и STT.
Подробный утверждённый дизайн находится в
[`docs/superpowers/specs/2026-06-28-yandex-chat-voice-design.md`](superpowers/specs/2026-06-28-yandex-chat-voice-design.md).

### Что потребуется в Yandex Cloud

1. Каталог с подключённым биллингом.
2. Сервисный аккаунт с ролями `ai.languageModels.user` и
   `ai.speechkit-stt.user`.
3. API-ключ сервисного аккаунта с областью
   `yc.ai.foundationModels.execute`.
4. Идентификатор каталога (`folder ID`).

Секретный API-ключ нельзя коммитить или передавать в чат. Он хранится только в
`config/.env` на сервере.

### Целевая конфигурация Hermes

После реализации миграции в `config/.env` будет достаточно следующего:

```dotenv
YANDEX_API_KEY=<секретный API-ключ сервисного аккаунта>
YANDEX_FOLDER_ID=<идентификатор каталога>
HERMES_MODEL_PROVIDER=custom:yandex
HERMES_MODEL=gpt://<идентификатор каталога>/yandexgpt
HERMES_STT_PROVIDER=yandex
```

Активная конфигурация Hermes в `/opt/data/config.yaml` должна иметь такой вид:

```yaml
custom_providers:
  - name: yandex
    base_url: https://ai.api.cloud.yandex.net/v1
    key_env: YANDEX_API_KEY
    api_mode: chat_completions

model:
  provider: custom:yandex
  default: gpt://<идентификатор каталога>/yandexgpt

stt:
  enabled: true
  provider: local_command
  local:
    language: ru
```

Полный URI модели содержит folder ID, поэтому Hermes может обращаться к
YandexGPT через обычный OpenAI-compatible custom endpoint. Точное имя
доступной модели проверяется через `/v1/models` во время настройки и может быть
переопределено переменной `HERMES_MODEL`.

> Важно: это целевое состояние, а не устойчивая ручная настройка текущей
> версии репозитория. Сейчас `scripts/setup-hermes.sh` принимает только ключи
> OpenRouter, OpenAI и Anthropic и при повторном запуске перезаписывает секцию
> `model`. Сначала необходимо реализовать изменения из технического дизайна.

### Пример проверки YandexGPT

На VPS после заполнения переменных можно проверить API независимо от Hermes:

```bash
curl --fail-with-body \
  --request POST https://ai.api.cloud.yandex.net/v1/chat/completions \
  --header "Authorization: Api-Key ${YANDEX_API_KEY}" \
  --header "OpenAI-Project: ${YANDEX_FOLDER_ID}" \
  --header "Content-Type: application/json" \
  --data '{
    "model": "gpt://'"${YANDEX_FOLDER_ID}"'/yandexgpt",
    "messages": [{"role": "user", "content": "Ответь одним словом: работает?"}],
    "max_tokens": 20
  }'
```

Отдельный smoke-test должен проверить function calling, потому что Hermes
использует tools, а не только текстовую генерацию.

### Пример распознавания длинного voice

SpeechKit v3 принимает Telegram OggOpus напрямую. Для сообщений длиннее 30
секунд используется асинхронный endpoint. Object Storage для принятой схемы не
нужен: содержимое файла передаётся в поле `content` как base64.

Упрощённый пример первого запроса:

```bash
AUDIO_B64=$(base64 -w0 voice.ogg)

curl --fail-with-body \
  --request POST https://stt.api.cloud.yandex.net/stt/v3/recognizeFileAsync \
  --header "Authorization: Api-Key ${YANDEX_API_KEY}" \
  --header "Content-Type: application/json" \
  --data '{
    "content": "'"${AUDIO_B64}"'",
    "recognitionModel": {
      "model": "general",
      "audioFormat": {
        "containerAudio": {"containerAudioType": "OGG_OPUS"}
      },
      "textNormalization": {
        "textNormalization": "TEXT_NORMALIZATION_ENABLED"
      },
      "languageRestriction": {
        "restrictionType": "WHITELIST",
        "languageCode": ["ru-RU"]
      }
    }
  }'
```

Ответ содержит `id` операции. STT-адаптер будет ждать её завершения с
ограниченным exponential backoff, затем получит результат через
`GET https://stt.api.cloud.yandex.net/stt/v3/getRecognition?operationId=<id>`
и запишет расшифровку в тот же `.txt`, который уже ожидает Hermes.

### Порядок безопасного переключения

1. Сделать резервные копии `config/.env` и `/opt/data/config.yaml`.
2. Добавить Yandex credentials, не удаляя OpenRouter credentials.
3. Выполнить независимые smoke-тесты YandexGPT и SpeechKit.
4. Переключить чат на `custom:yandex` и проверить обычный ответ и tool call.
5. Переключить `whisper` shim на SpeechKit и проверить voice длительностью не
   менее 90 секунд.
6. Перезапустить Telegram gateway и проверить сообщения end-to-end.
7. Только после стабильной проверки убрать обязательность
   `OPENROUTER_API_KEY`.

## Краткий вывод

Не следует заменять OpenRouter другим единственным агрегатором и сохранять
единую точку отказа. Для Hermes целесообразна схема из собственного gateway,
двух независимых LLM-провайдеров и отдельных резервов для распознавания речи и
генерации медиа.

Исходная provider-neutral рекомендация исследования:

```text
Hermes
  ├── primary LLM: Hugging Face Inference Providers или Together AI
  ├── fallback LLM: DeepSeek, Qwen, MiniMax или GigaChat
  ├── STT: local faster-whisper, Groq или Mistral
  ├── image generation: Together, Hugging Face или FAL
  └── routing: собственный LiteLLM Proxy на VPS
```

Для быстрого аварийного переключения лучше всего подходит нативный провайдер
Hugging Face в Hermes. Для долгосрочной устойчивости рекомендуется собственный
LiteLLM Proxy с несколькими независимыми upstream-провайдерами.

## Кандидаты

| Вариант | Применение | Преимущества | Ограничения |
|---|---|---|---|
| Hugging Face Inference Providers | Основной или резервный LLM | Нативно поддерживается Hermes, единый токен, множество open-weight моделей и inference-провайдеров | Нет закрытых моделей GPT, Claude и Gemini |
| Vercel AI Gateway | Облачная замена OpenRouter | Единый endpoint, большой каталог моделей, fallback, поддержка текста, речи и медиа | Иностранная единая точка отказа; перед миграцией необходимо проверить доступность и условия обслуживания |
| Requesty | Облачный gateway | Маршрутизация, BYOK, fallback, балансировка по стоимости и задержке | Поддержку необходимых video API требуется проверять отдельно |
| LiteLLM Proxy | Собственный gateway | OpenAI-compatible API, retries, fallback, маршрутизация, отсутствие зависимости от одного агрегатора | Нужно самостоятельно развернуть и сопровождать; требуются ключи upstream-провайдеров |
| Together AI | Open-weight LLM и мультимодальные задачи | LLM, vision, STT, TTS и изображения | Не предоставляет закрытые frontier-модели; video API требует отдельной интеграции |
| DeepSeek | Прямой LLM-провайдер | OpenAI-compatible API, простая интеграция, независимость от агрегатора | Покрывает только LLM-контур |
| Groq | Быстрый inference и STT | OpenAI-compatible API, низкая задержка, Whisper | Ограниченный набор моделей и отсутствие полной media-платформы |
| Fireworks AI | Open-weight inference | OpenAI-compatible интерфейс и большой выбор моделей | Доступность аккаунта, оплаты и конкретных моделей необходимо проверять заранее |
| GigaChat | Российский резервный LLM | Меньшая зависимость от внешних блокировок | Неполная совместимость с OpenAI API, OAuth и необходимость адаптера |
| Yandex AI Studio / SpeechKit | Российский LLM и STT-резерв | Локальная инфраструктура и отдельный речевой сервис | Не является полной drop-in заменой OpenRouter |
| Ollama / vLLM | Полностью локальный резерв | Нет зависимости от внешнего API | Нужны GPU-ресурсы; качество и скорость зависят от доступного оборудования |

## Почему прямых OpenAI и Anthropic недостаточно

Прямые OpenAI и Anthropic можно использовать только при наличии легально
поддерживаемой страны аккаунта, биллинга и инфраструктуры. Они не являются
надёжным аварийным вариантом для работы непосредственно из РФ. Перед
подключением необходимо сверять актуальные списки поддерживаемых стран и
условия использования.

## Фактические зависимости репозитория

OpenRouter используется не только как основной LLM:

1. Основной LLM:
   - `scripts/setup-hermes.sh` принимает только ключи OpenRouter, OpenAI и
     Anthropic;
   - провайдером по умолчанию задан `openrouter`;
   - моделью по умолчанию задана `openai/gpt-5.4-mini`.

2. Telegram voice STT:
   - `scripts/vps/openrouter-stt.py` обращается напрямую к
     `https://openrouter.ai/api/v1/chat/completions`;
   - проверки в `scripts/vps/check-voice.sh` требуют
     `OPENROUTER_API_KEY`.

3. Генерация изображений:
   - `plugins/image_gen/openrouter/__init__.py` использует OpenRouter Chat
     Completions;
   - plugin manifest требует `OPENROUTER_API_KEY`.

4. Генерация видео:
   - `plugins/video_gen/openrouter/__init__.py` использует OpenRouter Video API;
   - API отличается от обычного OpenAI-compatible chat endpoint, поэтому
     простая смена `base_url` его не заменит.

5. macOS:
   - vision и media-конфигурация в `scripts/macos/` явно выбирает провайдер
     `openrouter`.

Следовательно, простая смена LLM endpoint восстановит текстовый чат, но не
голосовые сообщения, анализ изображений и генерацию изображений/видео.

## Аварийный план

### Этап 1: восстановить основной чат

1. Зарегистрировать минимум двух независимых провайдеров.
2. Настроить один из нативных провайдеров Hermes:
   Hugging Face, DeepSeek, Qwen, MiniMax, Novita или Ollama.
3. Проверить обычный чат, tool calling, длинный контекст и Telegram gateway.
4. Не удалять OpenRouter-конфигурацию до завершения тестов.

Ожидаемый срок: несколько часов.

### Этап 2: восстановить голосовые сообщения

Предпочтительный порядок:

1. локальный `faster-whisper`, если VPS имеет достаточные CPU/RAM;
2. Groq Whisper;
3. Mistral transcription;
4. отдельный российский STT, например Yandex SpeechKit.

Текущий `openrouter-stt.py` следует заменить provider-neutral обёрткой или
отдельными STT backend-адаптерами.

Ожидаемый срок: до одного рабочего дня.

### Этап 3: убрать единую точку отказа

1. Развернуть LiteLLM Proxy на VPS.
2. Подключить минимум два upstream-провайдера.
3. Настроить retries, timeout, rate limits и fallback.
4. Направить Hermes на локальный OpenAI-compatible endpoint LiteLLM.
5. Добавить health check, который выполняет реальный минимальный inference.

Ожидаемый срок: один рабочий день.

### Этап 4: восстановить media-функции

1. Перевести image generation на Together, Hugging Face или FAL.
2. Для video generation выбрать отдельного провайдера и написать адаптер под
   его async job API.
3. Отвязать plugin names и переменные окружения от названия OpenRouter.
4. Добавить отдельные smoke-тесты для image и video endpoints.

Ожидаемый срок: один-два рабочих дня.

## Рекомендуемый порядок реализации в репозитории

1. Расширить список допустимых LLM-ключей и провайдеров в
   `scripts/setup-hermes.sh`.
2. Добавить конфигурацию custom endpoint:
   `HERMES_MODEL_BASE_URL`, `HERMES_MODEL_API_KEY` и
   `HERMES_MODEL_PROVIDER`.
3. Добавить fallback-цепочку в активный `config.yaml` Hermes.
4. Заменить `openrouter-stt.py` на общий STT adapter.
5. Создать provider-neutral image/video plugins.
6. Обновить проверки, документацию и integration-тесты.

## Критерии готовности

- Текстовый чат работает при полностью недоступном `openrouter.ai`.
- Telegram обрабатывает текстовые и голосовые сообщения.
- Отказ основного LLM автоматически переключает запрос на резервный.
- Ни один health check не зависит только от наличия API-ключа.
- Image/video функции либо работают через нового провайдера, либо явно
  отключены без падения основного агента.
- В конфигурации нет обязательного `OPENROUTER_API_KEY`.

## Источники

- [Hermes: LLM Providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- [Hugging Face Inference Providers для Hermes](https://huggingface.co/docs/inference-providers/integrations/hermes-agent)
- [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy)
- [Vercel AI Gateway](https://vercel.com/docs/ai-gateway)
- [Requesty documentation](https://docs.requesty.ai/quickstart)
- [GigaChat: совместимость с OpenAI API](https://developers.sber.ru/docs/ru/gigachat/guides/compatible-openai)
- [OpenAI: поддерживаемые страны и территории](https://help.openai.com/en/articles/5347006-openai-api-supported-countries-and-territories)

> Доступность провайдеров, поддерживаемые страны, цены, модели и способы оплаты
> меняются. Перед миграцией необходимо провести живой smoke-test с того же VPS,
> на котором работает production Hermes.
