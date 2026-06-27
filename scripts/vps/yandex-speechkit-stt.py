#!/usr/bin/env python3
"""Whisper-compatible speech-to-text adapter for Yandex SpeechKit v3."""

from __future__ import annotations

import base64
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable
from urllib.parse import quote


RECOGNIZE_URL = "https://stt.api.cloud.yandex.net/stt/v3/recognizeFileAsync"
OPERATIONS_URL = "https://operation.api.cloud.yandex.net/operations"
RESULT_URL = "https://stt.api.cloud.yandex.net/stt/v3/getRecognition"
HTTP_TIMEOUT = 120


CONTAINER_TYPES = {
    ".ogg": "OGG_OPUS",
    ".opus": "OGG_OPUS",
    ".wav": "WAV",
    ".mp3": "MP3",
}


def build_payload(audio: bytes, language: str, model: str, suffix: str) -> dict:
    """Build a SpeechKit v3 inline-file recognition request."""
    try:
        container_type = CONTAINER_TYPES[suffix.lower()]
    except KeyError as exc:
        supported = ", ".join(sorted(CONTAINER_TYPES))
        raise ValueError(
            f"unsupported audio format {suffix!r}; expected one of: {supported}"
        ) from exc

    language_code = "ru-RU" if language.lower() in {"ru", "ru-ru"} else language
    return {
        "content": base64.b64encode(audio).decode("ascii"),
        "recognitionModel": {
            "model": model,
            "audioFormat": {
                "containerAudio": {"containerAudioType": container_type}
            },
            "textNormalization": {
                "textNormalization": "TEXT_NORMALIZATION_ENABLED"
            },
            "languageRestriction": {
                "restrictionType": "WHITELIST",
                "languageCode": [language_code],
            },
        },
    }


def decode_events(raw: bytes) -> list[dict]:
    """Decode REST output returned as JSON, a list, or JSON Lines."""
    text = raw.decode("utf-8").strip()
    if not text:
        return []
    try:
        parsed = json.loads(text)
        values = parsed if isinstance(parsed, list) else [parsed]
    except json.JSONDecodeError:
        values = [json.loads(line) for line in text.splitlines() if line.strip()]
    return [
        value.get("result", value)
        for value in values
        if isinstance(value, dict)
    ]


def extract_transcript(events: list[dict]) -> str:
    """Return ordered final text, preferring normalized refinements."""
    finals: list[str] = []
    refinements: dict[int, str] = {}
    for event in events:
        final = event.get("final")
        if isinstance(final, dict):
            alternatives = final.get("alternatives") or []
            if alternatives:
                finals.append(str(alternatives[0].get("text", "")).strip())

        refinement = event.get("finalRefinement")
        if isinstance(refinement, dict):
            alternatives = (
                refinement.get("normalizedText", {}).get("alternatives") or []
            )
            if alternatives:
                index = int(refinement.get("finalIndex", len(refinements)))
                refinements[index] = str(
                    alternatives[0].get("text", "")
                ).strip()

    transcript = " ".join(
        refinements.get(index, text)
        for index, text in enumerate(finals)
        if refinements.get(index, text)
    ).strip()
    if not transcript:
        raise ValueError("SpeechKit returned no final transcript")
    return transcript


def _redacted_http_error(exc: urllib.error.HTTPError, headers: dict[str, str]) -> RuntimeError:
    detail = exc.read().decode("utf-8", "replace")[:500]
    authorization = headers.get("Authorization", "")
    secret = authorization.split(" ", 1)[1] if " " in authorization else ""
    if secret:
        detail = detail.replace(secret, "[REDACTED]")
    return RuntimeError(f"SpeechKit HTTP {exc.code}: {detail}")


def _request_bytes_with_retry(
    request: urllib.request.Request,
    headers: dict[str, str],
    opener: Callable,
    sleeper: Callable[[float], None],
    max_attempts: int = 3,
) -> bytes:
    for attempt in range(max_attempts):
        try:
            with opener(request, timeout=HTTP_TIMEOUT) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            transient = exc.code == 429 or 500 <= exc.code < 600
            if transient and attempt + 1 < max_attempts:
                exc.read()
                sleeper(float(2**attempt))
                continue
            raise _redacted_http_error(exc, headers) from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"SpeechKit request failed: {exc.reason}") from exc
    raise RuntimeError("SpeechKit request retry loop exhausted")


def request_json(
    url: str,
    headers: dict[str, str],
    payload: dict | None,
    opener: Callable = urllib.request.urlopen,
    sleeper: Callable[[float], None] = time.sleep,
) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        headers=headers,
        method="POST" if payload is not None else "GET",
    )
    value = json.loads(
        _request_bytes_with_retry(request, headers, opener, sleeper).decode("utf-8")
    )
    if not isinstance(value, dict):
        raise ValueError("SpeechKit returned a non-object JSON response")
    return value


def transcribe(
    audio_path: Path,
    api_key: str,
    folder_id: str,
    language: str,
    model: str,
    timeout: float,
    opener: Callable = urllib.request.urlopen,
    sleeper: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> str:
    """Submit audio, wait for the async operation, and return final text."""
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
        sleeper,
    )
    operation_id = str(operation.get("id", "")).strip()
    if not operation_id:
        raise ValueError("SpeechKit did not return an operation id")

    deadline = clock() + timeout
    delay = 1.0
    while True:
        state = request_json(
            f"{OPERATIONS_URL}/{quote(operation_id, safe='')}",
            headers,
            None,
            opener,
            sleeper,
        )
        if state.get("done"):
            error = state.get("error")
            if isinstance(error, dict):
                raise RuntimeError(
                    str(error.get("message") or "SpeechKit operation failed")
                )
            break
        if clock() >= deadline:
            raise TimeoutError(f"SpeechKit operation exceeded {timeout:g}s")
        sleeper(delay)
        delay = min(delay * 2, 10.0)

    result_request = urllib.request.Request(
        f"{RESULT_URL}?operationId={quote(operation_id, safe='')}",
        headers=headers,
        method="GET",
    )
    result = _request_bytes_with_retry(result_request, headers, opener, sleeper)
    return extract_transcript(decode_events(result))


def parse_args(argv: list[str]) -> dict[str, str | None]:
    """Parse the subset of the whisper CLI used by Hermes."""
    opts: dict[str, str | None] = {
        "audio": None,
        "output_dir": ".",
        "output_format": "txt",
        "language": "ru",
    }
    known_value_flags = {
        "--output_dir": "output_dir",
        "--output_format": "output_format",
        "--language": "language",
    }
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in known_value_flags and index + 1 < len(argv):
            opts[known_value_flags[arg]] = argv[index + 1]
            index += 2
            continue
        if arg.startswith("-"):
            if index + 1 < len(argv) and not argv[index + 1].startswith("-"):
                index += 2
            else:
                index += 1
            continue
        if opts["audio"] is None:
            opts["audio"] = arg
        index += 1
    return opts


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temp_file:
            temp_file.write(content)
            temp_name = temp_file.name
        os.replace(temp_name, path)
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"{name} is not set")
    return value


def main(
    argv: list[str] | None = None,
    transcriber: Callable = transcribe,
) -> int:
    opts = parse_args(sys.argv[1:] if argv is None else argv)
    audio_value = opts["audio"]
    if not audio_value:
        raise ValueError("no input audio file given")

    api_key = require_env("YANDEX_API_KEY")
    folder_id = require_env("YANDEX_FOLDER_ID")
    model = os.environ.get("HERMES_YANDEX_STT_MODEL", "general").strip() or "general"
    timeout = float(os.environ.get("HERMES_YANDEX_STT_TIMEOUT", "600"))
    language = str(opts["language"] or "ru")
    transcript = transcriber(
        Path(str(audio_value)),
        api_key,
        folder_id,
        language,
        model,
        timeout,
    )

    output_format = str(opts["output_format"] or "txt")
    if output_format not in {"txt", "vtt", "srt", "json"}:
        output_format = "txt"
    output_path = (
        Path(str(opts["output_dir"] or "."))
        / f"{Path(str(audio_value)).stem}.{output_format}"
    )
    atomic_write(output_path, transcript + "\n")
    print(transcript)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError, ValueError) as exc:
        raise SystemExit(f"yandex-speechkit-stt: {exc}") from exc
