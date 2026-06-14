# Web и генерация медиа

Нативная macOS-установка включает глобальные способности:

- `web_search` через zero-key backend DDGS;
- `web_extract` для чтения конкретных страниц;
- анализ изображений и видео через vision-модель OpenRouter;
- генерацию изображений через OpenRouter Chat Completions;
- генерацию видео через OpenRouter async Video API;
- локальное распознавание речи и системный macOS TTS.

## Модели

Defaults задаются в `config/macos.env`:

```env
HERMES_VISION_MODEL=google/gemini-3-flash-preview
HERMES_OPENROUTER_IMAGE_MODEL=google/gemini-2.5-flash-image
HERMES_OPENROUTER_VIDEO_MODEL=google/veo-3.1-lite
```

Image/video generation использует уже настроенный `OPENROUTER_API_KEY`.
Providers устанавливаются в:

```text
~/.hermes/plugins/image_gen/openrouter/
~/.hermes/plugins/video_gen/openrouter/
```

Upstream checkout Hermes не изменяется.

## Проверка без расходов

```bash
make check-web-media
make check-multimedia
```

`check-web-media` выполняет живой бесплатный web search и проверяет регистрацию
media providers. Он не запускает платную генерацию.

## Платный smoke-test

Изображение можно проверить запросом агенту:

```text
Создай квадратное тестовое изображение: красный круг на белом фоне.
Используй image_generate.
```

Перед video generation следует подтвердить расходы и выбранную модель. Видео
может генерироваться несколько минут; provider опрашивает async job и сохраняет
MP4 в `~/.hermes/cache/videos/`.

## Правила использования

- Для актуальных фактов сначала использовать `web_search`, затем
  `web_extract` для первичного источника.
- Не выдавать результаты поиска из памяти модели за актуальную проверку.
- Перед дорогостоящей генерацией видео показывать модель и параметры.
- Сгенерированные файлы хранить в cache; важные результаты переносить в
  постоянное хранилище отдельно.
