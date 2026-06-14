#!/usr/bin/env python3
"""Install OpenRouter media providers and select them in Hermes."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import yaml


PLUGIN_KEYS = ("image_gen/openrouter", "video_gen/openrouter")


def sync_tree(source: Path, target: Path) -> None:
    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--hermes-home", type=Path, required=True)
    parser.add_argument("--image-model", required=True)
    parser.add_argument("--video-model", required=True)
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    home = args.hermes_home.expanduser()
    for category in ("image_gen", "video_gen"):
        sync_tree(
            repo_root / "plugins" / category / "openrouter",
            home / "plugins" / category / "openrouter",
        )

    config_path = home / "config.yaml"
    config = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
    plugins = config.setdefault("plugins", {})
    enabled = set(plugins.get("enabled") or [])
    enabled.update(PLUGIN_KEYS)
    plugins["enabled"] = sorted(enabled)
    config["image_gen"] = {
        **(config.get("image_gen") or {}),
        "provider": "openrouter",
        "model": args.image_model,
    }
    config["video_gen"] = {
        **(config.get("video_gen") or {}),
        "provider": "openrouter",
        "model": args.video_model,
    }
    config_path.write_text(
        yaml.safe_dump(config, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
