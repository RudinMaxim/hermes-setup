# Yandex Console Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить запускаемый одной командой интерактивный Bash-скрипт, который безопасно переводит Hermes chat и Telegram voice с OpenRouter на Yandex AI Studio и SpeechKit.

**Architecture:** `scripts/migrate-to-yandex.sh` собирает секретный API key и folder ID, делает backup, сохраняет конфигурацию и запускает существующие idempotent setup-контуры. `scripts/setup-hermes.sh` получает first-class конфигурацию именованного custom provider `yandex`, а provider-neutral `scripts/lib/voice.sh` разворачивает whisper-compatible SpeechKit v3 adapter. Адаптер отправляет OggOpus inline, ждёт async operation и возвращает нормализованный transcript в формате, уже ожидаемом Hermes.

**Tech Stack:** Bash 4+, Docker Compose, Python 3 standard library, YAML внутри Hermes image, Bats, Python `unittest`.

---

## Карта файлов

- Create `scripts/migrate-to-yandex.sh`: интерактивная точка входа, backup и orchestration.
- Create `scripts/vps/yandex-speechkit-stt.py`: whisper-compatible SpeechKit v3 adapter.
- Create `tests/unit/test_yandex_speechkit_stt.py`: unit-тесты payload, polling и transcript parsing.
- Create `tests/unit/test_migrate_to_yandex.bats`: тесты prompts, secret persistence и orchestration со stub-командами.
- Modify `scripts/setup-hermes.sh`: Yandex credential и persistent custom provider.
- Modify `scripts/lib/voice.sh`: выбор Yandex/OpenRouter backend и self-healing symlink.
- Modify `scripts/vps/check-voice.sh`: backend-aware readiness checks.
- Modify `config/.env.example`: Yandex settings и Yandex default для Plan A.
- Modify `tests/integration/test_hermes_setup.bats`: Yandex setup regression tests.
- Modify `tests/integration/test_gateway_setup.bats`: Yandex voice self-healing tests.
- Modify `docs/02-hermes-setup.md`: одна команда запуска и rollback.

### Task 1: SpeechKit v3 adapter

**Files:**
- Create: `tests/unit/test_yandex_speechkit_stt.py`
- Create: `scripts/vps/yandex-speechkit-stt.py`

- [ ] **Step 1: Write failing payload and transcript tests**

Load the not-yet-existing script with `importlib.util`, then define concrete tests:

```python
class YandexSpeechKitSttTest(unittest.TestCase):
    def test_build_payload_embeds_ogg_opus_and_russian_language(self):
        payload = module.build_payload(b"opus", "ru", "general", ".ogg")
        self.assertEqual(payload["content"], "b3B1cw==")
        model = payload["recognitionModel"]
        self.assertEqual(model["audioFormat"]["containerAudio"]["containerAudioType"], "OGG_OPUS")
        self.assertEqual(model["languageRestriction"]["languageCode"], ["ru-RU"])

    def test_extract_transcript_prefers_normalized_refinements(self):
        events = [
            {"final": {"alternatives": [{"text": "привет мир"}]}},
            {"finalRefinement": {"finalIndex": "0", "normalizedText": {"alternatives": [{"text": "Привет, мир."}]}}},
        ]
        self.assertEqual(module.extract_transcript(events), "Привет, мир.")
```

- [ ] **Step 2: Run tests to verify RED**

Run: `python -m unittest tests.unit.test_yandex_speechkit_stt -v`

Expected: FAIL because `scripts/vps/yandex-speechkit-stt.py` does not exist.

- [ ] **Step 3: Implement payload and transcript parsing**

Implement these exact public boundaries:

```python
def build_payload(audio: bytes, language: str, model: str, suffix: str) -> dict:
    containers = {".ogg": "OGG_OPUS", ".opus": "OGG_OPUS", ".wav": "WAV", ".mp3": "MP3"}
    container = containers[suffix.lower()]
    language_code = "ru-RU" if language.lower() in {"ru", "ru-ru"} else language
    return {
        "content": base64.b64encode(audio).decode("ascii"),
        "recognitionModel": {
            "model": model,
            "audioFormat": {"containerAudio": {"containerAudioType": container}},
            "textNormalization": {"textNormalization": "TEXT_NORMALIZATION_ENABLED"},
            "languageRestriction": {
                "restrictionType": "WHITELIST",
                "languageCode": [language_code],
            },
        },
    }


def decode_events(raw: bytes) -> list[dict]:
    text = raw.decode("utf-8").strip()
    try:
        value = json.loads(text)
        values = value if isinstance(value, list) else [value]
    except json.JSONDecodeError:
        values = [json.loads(line) for line in text.splitlines() if line.strip()]
    return [value.get("result", value) for value in values if isinstance(value, dict)]


def extract_transcript(events: list[dict]) -> str:
    finals: list[str] = []
    refinements: dict[int, str] = {}
    for event in events:
        if "final" in event:
            alternatives = event["final"].get("alternatives") or []
            if alternatives:
                finals.append(alternatives[0].get("text", "").strip())
        if "finalRefinement" in event:
            refinement = event["finalRefinement"]
            alternatives = refinement.get("normalizedText", {}).get("alternatives") or []
            if alternatives:
                refinements[int(refinement["finalIndex"])] = alternatives[0].get("text", "").strip()
    transcript = " ".join(refinements.get(index, text) for index, text in enumerate(finals)).strip()
    if not transcript:
        raise ValueError("SpeechKit returned no final transcript")
    return transcript
```

`build_payload` maps `.ogg`/`.opus` to `OGG_OPUS`, `.wav` to `WAV`, `.mp3` to `MP3`, enables normalization and converts `ru` to `ru-RU`. `decode_events` accepts a JSON object, a JSON list, `{"result": event}` wrappers and newline-delimited JSON. `extract_transcript` replaces raw `final` text by matching `finalRefinement.finalIndex`, preserves final order and rejects an empty result.

- [ ] **Step 4: Add failing polling and CLI tests**

Use a local fake `urlopen` callable returning: operation creation, `done=false`, `done=true`, and GetRecognition events. Assert `Authorization: Api-Key`, `x-folder-id`, timeout behavior, `<stem>.txt`, and stdout.

- [ ] **Step 5: Run tests to verify RED**

Run: `python -m unittest tests.unit.test_yandex_speechkit_stt -v`

Expected: payload tests PASS; polling/CLI tests FAIL because `transcribe` and `main` are absent.

- [ ] **Step 6: Implement async recognition and CLI**

Add:

```python
def transcribe(audio_path: Path, api_key: str, folder_id: str, language: str,
               model: str, timeout: float, opener=urllib.request.urlopen,
               sleeper=time.sleep, clock=time.monotonic) -> str:
    headers = {
        "Authorization": f"Api-Key {api_key}",
        "x-folder-id": folder_id,
        "Content-Type": "application/json",
    }
    operation = request_json(
        RECOGNIZE_URL,
        headers,
        build_payload(audio_path.read_bytes(), language, model, audio_path.suffix),
        opener,
    )
    operation_id = operation["id"]
    deadline = clock() + timeout
    delay = 1.0
    while True:
        state = request_json(f"{OPERATIONS_URL}/{quote(operation_id)}", headers, None, opener)
        if state.get("done"):
            if state.get("error"):
                raise RuntimeError(state["error"].get("message", "SpeechKit operation failed"))
            break
        if clock() >= deadline:
            raise TimeoutError(f"SpeechKit operation exceeded {timeout:g}s")
        sleeper(delay)
        delay = min(delay * 2, 10.0)
    request = urllib.request.Request(
        f"{RESULT_URL}?operationId={quote(operation_id)}",
        headers=headers,
        method="GET",
    )
    with opener(request, timeout=HTTP_TIMEOUT) as response:
        return extract_transcript(decode_events(response.read()))


def main(argv: list[str] | None = None) -> int:
    opts = parse_args(sys.argv[1:] if argv is None else argv)
    api_key = require_env("YANDEX_API_KEY")
    folder_id = require_env("YANDEX_FOLDER_ID")
    transcript = transcribe(
        Path(opts["audio"]), api_key, folder_id, opts["language"],
        os.environ.get("HERMES_YANDEX_STT_MODEL", "general"),
        float(os.environ.get("HERMES_YANDEX_STT_TIMEOUT", "600")),
    )
    output = Path(opts["output_dir"]) / f"{Path(opts['audio']).stem}.{opts['output_format']}"
    atomic_write(output, transcript + "\n")
    print(transcript)
    return 0
```

POST to `https://stt.api.cloud.yandex.net/stt/v3/recognizeFileAsync`, poll `https://operation.api.cloud.yandex.net/operations/{id}` with bounded exponential delays, then GET `https://stt.api.cloud.yandex.net/stt/v3/getRecognition?operationId={id}`. Read `YANDEX_API_KEY`, `YANDEX_FOLDER_ID`, `HERMES_YANDEX_STT_MODEL` and `HERMES_YANDEX_STT_TIMEOUT`; never include credentials or audio payloads in errors.

- [ ] **Step 7: Run tests and syntax check**

Run:

```bash
python -m unittest tests.unit.test_yandex_speechkit_stt -v
python -m py_compile scripts/vps/yandex-speechkit-stt.py
```

Expected: all tests PASS; syntax check exits 0.

- [ ] **Step 8: Commit adapter**

```bash
git add scripts/vps/yandex-speechkit-stt.py tests/unit/test_yandex_speechkit_stt.py
git commit -m "feat: add Yandex SpeechKit STT adapter"
```

### Task 2: Persistent Yandex chat configuration

**Files:**
- Modify: `tests/integration/test_hermes_setup.bats`
- Modify: `scripts/setup-hermes.sh`
- Modify: `config/.env.example`

- [ ] **Step 1: Add failing setup tests**

Add tests which configure only `YANDEX_API_KEY`, `YANDEX_FOLDER_ID`, `HERMES_MODEL_PROVIDER=custom:yandex`, and `HERMES_MODEL=gpt://folder/aliceai-llm`; assert `--configs-only` exits 0. `aliceai-llm` is the Yandex-native default because its context is at least 64k; YandexGPT Pro 5.x is limited to 32k and does not meet Hermes' agent context requirement. In the docker-stub test capture stdin passed to `docker exec -i hermes python3` and assert it contains:

```python
custom_providers = config.get("custom_providers") or []
"base_url": "https://ai.api.cloud.yandex.net/v1"
"key_env": "YANDEX_API_KEY"
"api_mode": "chat_completions"
```

- [ ] **Step 2: Run setup tests to verify RED**

Run: `bats tests/integration/test_hermes_setup.bats`

Expected: Yandex-only credential test FAILS with `no LLM API key configured`.

- [ ] **Step 3: Implement Yandex provider setup**

Extend `ensure_llm_key` to accept and prompt for `yandex`. Extend `ensure_model_config` so `provider == "custom:yandex"` upserts this entry without removing unrelated providers:

```python
yandex = {
    "name": "yandex",
    "base_url": "https://ai.api.cloud.yandex.net/v1",
    "key_env": "YANDEX_API_KEY",
    "api_mode": "chat_completions",
}
```

Require non-empty `YANDEX_FOLDER_ID` for Yandex and keep the selected full model URI across repeat runs. Add documented Yandex variables to `.env.example` while leaving legacy provider keys available.

- [ ] **Step 4: Run setup tests and shell syntax**

Run:

```bash
bats tests/integration/test_hermes_setup.bats
bash -n scripts/setup-hermes.sh
```

Expected: all setup tests PASS; syntax exits 0.

- [ ] **Step 5: Commit chat setup**

```bash
git add config/.env.example scripts/setup-hermes.sh tests/integration/test_hermes_setup.bats
git commit -m "feat: configure YandexGPT provider"
```

### Task 3: Provider-aware voice self-healing

**Files:**
- Modify: `tests/integration/test_gateway_setup.bats`
- Modify: `scripts/lib/voice.sh`
- Modify: `scripts/vps/check-voice.sh`

- [ ] **Step 1: Convert gateway stubs and add failing Yandex assertions**

Configure test `.env` with `HERMES_STT_PROVIDER=yandex`, `YANDEX_API_KEY=test`, and `YANDEX_FOLDER_ID=folder`. Assert setup deploys `/opt/data/bin/yandex-speechkit-stt.py`, links `whisper` to it, and does not inspect `OPENROUTER_API_KEY`.

- [ ] **Step 2: Run gateway tests to verify RED**

Run: `bats tests/integration/test_gateway_setup.bats`

Expected: voice deployment tests FAIL because `voice.sh` still hardcodes OpenRouter.

- [ ] **Step 3: Implement backend selection**

Read `HERMES_STT_PROVIDER` from `config/.env`, default to `yandex` when Yandex credentials exist and otherwise preserve `openrouter`. Resolve backend script/key/model through small shell functions. Deploy the selected file, write a symlink containing its basename, and keep `stt.provider=local_command` unchanged.

- [ ] **Step 4: Make `check-voice.sh` backend-aware**

Read provider and verify the matching script, symlink and required variables. For Yandex, report structural readiness and direct the operator to a Telegram voice smoke-test; do not send paid audio automatically.

- [ ] **Step 5: Run tests and syntax checks**

Run:

```bash
bats tests/integration/test_gateway_setup.bats
bash -n scripts/lib/voice.sh scripts/vps/check-voice.sh
```

Expected: all gateway tests PASS; syntax exits 0.

- [ ] **Step 6: Commit voice routing**

```bash
git add scripts/lib/voice.sh scripts/vps/check-voice.sh tests/integration/test_gateway_setup.bats
git commit -m "feat: route Telegram voice through SpeechKit"
```

### Task 4: Pasteable interactive migration command

**Files:**
- Create: `tests/unit/test_migrate_to_yandex.bats`
- Create: `scripts/migrate-to-yandex.sh`

- [ ] **Step 1: Write failing migration tests**

Use a temporary repo fixture and stub `bash`/`docker`. Feed three input lines (`API key`, `folder ID`, empty model override) and assert:

```bash
grep -qx 'YANDEX_API_KEY=test-secret' "$ENVFILE"
grep -qx 'YANDEX_FOLDER_ID=b1gtestfolder' "$ENVFILE"
grep -qx 'HERMES_MODEL_PROVIDER=custom:yandex' "$ENVFILE"
grep -qx 'HERMES_MODEL=gpt://b1gtestfolder/aliceai-llm' "$ENVFILE"
grep -qx 'HERMES_STT_PROVIDER=yandex' "$ENVFILE"
test -f "$ENVFILE.backup-"*
```

Also assert stdout/stderr never contains `test-secret`, and non-interactive execution without credentials fails before any Docker call.

- [ ] **Step 2: Run migration tests to verify RED**

Run: `bats tests/unit/test_migrate_to_yandex.bats`

Expected: FAIL because `scripts/migrate-to-yandex.sh` does not exist.

- [ ] **Step 3: Implement the migration script**

The script must:

```bash
api_key="${YANDEX_API_KEY:-}"
folder_id="${YANDEX_FOLDER_ID:-}"
[[ -n "$api_key" ]] || api_key=$(prompt_secret "YANDEX_API_KEY")
[[ -n "$folder_id" ]] || folder_id=$(prompt_value "YANDEX_FOLDER_ID")
model="${HERMES_MODEL:-gpt://${folder_id}/aliceai-llm}"
```

Validate the values, create timestamped backups with mode `0600`, use `set_env_value` for five settings, call `scripts/setup-hermes.sh`, then `scripts/setup-gateway.sh --restart` when Telegram is enabled. If Telegram is disabled, force-recreate the base compose service so the container receives the new environment. On any failure, print backup paths and the exact restore commands without exposing the key.

- [ ] **Step 4: Run migration tests and shell syntax**

Run:

```bash
bats tests/unit/test_migrate_to_yandex.bats
bash -n scripts/migrate-to-yandex.sh
```

Expected: all tests PASS; syntax exits 0.

- [ ] **Step 5: Commit migration entrypoint**

```bash
git add scripts/migrate-to-yandex.sh tests/unit/test_migrate_to_yandex.bats
git commit -m "feat: add interactive Yandex migration script"
```

### Task 5: Operator documentation and full verification

**Files:**
- Modify: `docs/02-hermes-setup.md`
- Modify: `docs/openrouter-alternatives.md`

- [ ] **Step 1: Document the one-command workflow**

Add the exact operator command:

```bash
cd ~/hermes-setup
git pull
bash scripts/migrate-to-yandex.sh
```

Document that API key input is hidden, folder ID is visible, backups are created automatically, and the final manual gate is a Telegram voice message longer than 30 seconds.

- [ ] **Step 2: Run all focused tests**

```bash
python -m unittest tests.unit.test_yandex_speechkit_stt -v
bats tests/unit/test_migrate_to_yandex.bats
bats tests/integration/test_hermes_setup.bats
bats tests/integration/test_gateway_setup.bats
bash -n scripts/migrate-to-yandex.sh scripts/setup-hermes.sh scripts/lib/voice.sh scripts/vps/check-voice.sh
git diff --check
```

Expected: all tests PASS and all syntax/diff checks exit 0.

- [ ] **Step 3: Review secrets and OpenRouter coupling**

Run:

```bash
git diff -- . ':!docs/superpowers/plans/*' | grep -E 'YANDEX_API_KEY=[^<[:space:]]|test-secret' && exit 1 || true
rg -n 'OPENROUTER_API_KEY' scripts/setup-hermes.sh scripts/lib/voice.sh scripts/vps/check-voice.sh
```

Expected: no real Yandex secret; remaining OpenRouter matches are explicit legacy fallback paths only.

- [ ] **Step 4: Commit docs**

```bash
git add docs/02-hermes-setup.md docs/openrouter-alternatives.md docs/superpowers/plans/2026-06-28-yandex-console-migration.md
git commit -m "docs: add Yandex migration runbook"
```

- [ ] **Step 5: Final verification**

Run the focused test block from Step 2 again after the final commit and inspect `git status --short`.

Expected: all commands exit 0 and the worktree is clean.
