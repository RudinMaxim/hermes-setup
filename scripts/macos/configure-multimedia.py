#!/usr/bin/env python3
"""Configure native macOS STT/TTS and OpenRouter multimodal analysis."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import yaml


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tts-script", required=True)
    args = parser.parse_args()

    hermes_home = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
    config_path = hermes_home / "config.yaml"
    config = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}

    stt_model = os.environ.get("HERMES_STT_MODEL", "base")
    stt_language = os.environ.get("HERMES_STT_LANGUAGE", "ru")
    tts_voice = os.environ.get("HERMES_TTS_VOICE", "Milena")
    vision_model = os.environ.get(
        "HERMES_VISION_MODEL", "google/gemini-3-flash-preview"
    )

    config["stt"] = {
        **(config.get("stt") or {}),
        "enabled": True,
        "provider": "local_command",
        "local": {
            **((config.get("stt") or {}).get("local") or {}),
            "model": stt_model,
            "language": stt_language,
        },
    }

    tts = config.setdefault("tts", {})
    tts["provider"] = "macos-say"
    providers = tts.setdefault("providers", {})
    providers["macos-say"] = {
        "type": "command",
        "command": (
            f"/bin/bash {args.tts_script} "
            "{input_path} {output_path} {voice}"
        ),
        "output_format": "ogg",
        "voice_compatible": True,
        "voice": tts_voice,
        "timeout": 120,
        "max_text_length": 5000,
    }

    auxiliary = config.setdefault("auxiliary", {})
    vision = auxiliary.setdefault("vision", {})
    vision.update(
        {
            "provider": "openrouter",
            "model": vision_model,
            "timeout": 240,
            "download_timeout": 60,
        }
    )

    voice = config.setdefault("voice", {})
    voice.setdefault("record_key", "ctrl+b")
    voice.setdefault("max_recording_seconds", 120)
    voice.setdefault("beep_enabled", True)

    config_path.write_text(
        yaml.safe_dump(config, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
