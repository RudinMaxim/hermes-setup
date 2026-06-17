#!/usr/bin/env python3
"""Drop-in whisper-compatible STT shim that transcribes via OpenRouter.

Hermes' `stt.provider = local_command` backend shells out to the `whisper`
binary, e.g.:

    whisper /path/voice.ogg --model base --language ru \
        --output_dir /opt/data/tmp --output_format txt

The local `openai-whisper` `base` model is too weak for real Russian speech
over Telegram's compressed Opus audio, so transcriptions come out garbled and
the agent then answers the garbage. Larger whisper models (medium/large) give
good Russian but need 5-10 GB RAM, which does not fit a 3 GB VPS.

This shim keeps the exact whisper CLI surface (so no Hermes config change is
needed) but routes the audio to an OpenRouter audio-capable model instead. It
costs a few cents per minute, runs off-box (near-zero CPU/RAM on the VPS), and
gives much better Russian recognition.

Requires OPENROUTER_API_KEY in the environment (already present in the Hermes
container for the video-gen plugin) and ffmpeg on PATH.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
DEFAULT_MODEL = "google/gemini-2.5-flash"
DEFAULT_LANGUAGE = "ru"
HTTP_TIMEOUT = 120


def _parse_args(argv: list[str]) -> dict:
    """Parse the subset of the whisper CLI that Hermes actually uses.

    Unknown flags are tolerated: a `--flag value` pair is skipped, a bare
    positional (not starting with `-`) is treated as the input audio file.
    """
    opts = {
        "audio": None,
        "output_dir": ".",
        "output_format": "txt",
        "language": DEFAULT_LANGUAGE,
    }
    known_value_flags = {
        "--output_dir": "output_dir",
        "--language": "language",
        "--output_format": "output_format",
    }
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in known_value_flags and i + 1 < len(argv):
            opts[known_value_flags[arg]] = argv[i + 1]
            i += 2
            continue
        if arg.startswith("-"):
            # Unknown flag (e.g. --model, --device). Skip it and, if the next
            # token is its value rather than another flag, skip that too.
            if i + 1 < len(argv) and not argv[i + 1].startswith("-"):
                i += 2
            else:
                i += 1
            continue
        if opts["audio"] is None:
            opts["audio"] = arg
        i += 1
    return opts


def _to_mp3(audio_path: str) -> bytes:
    """Transcode any input (Telegram OGG/Opus, etc.) to mono 16 kHz mp3."""
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
        out_path = tmp.name
    try:
        subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-i", audio_path, "-ac", "1", "-ar", "16000",
                "-f", "mp3", out_path,
            ],
            check=True,
        )
        return Path(out_path).read_bytes()
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass


def _transcribe(mp3_bytes: bytes, language: str) -> str:
    api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("openrouter-stt: OPENROUTER_API_KEY is not set")
    model = os.environ.get("HERMES_OPENROUTER_STT_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL
    b64 = base64.b64encode(mp3_bytes).decode("ascii")
    payload = {
        "model": model,
        "temperature": 0,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "Точно и дословно расшифруй речь из аудио. "
                            f"Язык речи: {language}. "
                            "Верни ТОЛЬКО текст расшифровки, без пояснений, "
                            "без кавычек и без перевода."
                        ),
                    },
                    {
                        "type": "input_audio",
                        "input_audio": {"data": b64, "format": "mp3"},
                    },
                ],
            }
        ],
    }
    req = urllib.request.Request(
        OPENROUTER_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/RudinMaxim/hermes-setup",
            "X-Title": "Hermes Agent STT",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        raise SystemExit(f"openrouter-stt: HTTP {exc.code}: {detail}")
    except urllib.error.URLError as exc:
        raise SystemExit(f"openrouter-stt: request failed: {exc.reason}")
    try:
        text = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise SystemExit(f"openrouter-stt: unexpected response: {json.dumps(body)[:500]}")
    if isinstance(text, list):  # some models return content as parts
        text = "".join(part.get("text", "") for part in text if isinstance(part, dict))
    return (text or "").strip()


def main() -> None:
    opts = _parse_args(sys.argv[1:])
    if not opts["audio"]:
        raise SystemExit("openrouter-stt: no input audio file given")

    transcript = _transcribe(_to_mp3(opts["audio"]), opts["language"])

    # Mirror whisper's behaviour: write <output_dir>/<stem>.<ext> AND print to
    # stdout, so this works whether Hermes reads the file or captures stdout.
    out_dir = Path(opts["output_dir"])
    out_dir.mkdir(parents=True, exist_ok=True)
    ext = opts["output_format"] if opts["output_format"] in {"txt", "vtt", "srt", "json"} else "txt"
    stem = Path(opts["audio"]).stem
    (out_dir / f"{stem}.{ext}").write_text(transcript + "\n", encoding="utf-8")

    print(transcript)


if __name__ == "__main__":
    main()
