#!/usr/bin/env python3
"""Apply Mac mini operational rules to configured Telegram chats."""

from __future__ import annotations

import os
from pathlib import Path

import yaml


RULE_MARKER = "[hermes-setup mac-mini rules]"
RULE_TEXT = """[hermes-setup mac-mini rules]
Todoist MCP:
- For a general overview, call get-overview without projectId.
- For a specific project, call find-projects first and use only the returned real ID.
- INVALID_ARGUMENT_VALUE is an argument error, not an OAuth failure.
- If the MCP circuit breaker opens, wait for its roughly 60-second cooldown and retry once. Do not ask for OAuth unless the server reports invalid_grant or needs_reauth.
"""


def main() -> None:
    hermes_home = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
    config_path = hermes_home / "config.yaml"
    config = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}

    telegram = config.setdefault("telegram", {})
    allowed = str(telegram.get("allowed_chats") or "")
    chat_ids = [value.strip() for value in allowed.split(",") if value.strip()]
    if not chat_ids:
        raise SystemExit("telegram.allowed_chats is empty")

    prompts = telegram.setdefault("channel_prompts", {})
    for chat_id in chat_ids:
        current = str(prompts.get(chat_id) or "")
        if RULE_MARKER in current:
            continue
        prompts[chat_id] = f"{current.rstrip()}\n\n{RULE_TEXT}".strip()

    config_path.write_text(
        yaml.safe_dump(config, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
