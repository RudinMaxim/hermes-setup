#!/usr/bin/env python3
"""Apply Mac mini operational rules to configured Telegram chats."""

from __future__ import annotations

import os
from pathlib import Path

import yaml


RULE_MARKER = "[hermes-setup mac-mini rules v4]"
LEGACY_RULE_MARKERS = (
    "[hermes-setup mac-mini rules v3]",
    "[hermes-setup mac-mini rules v2]",
)
RULE_TEXT = """[hermes-setup mac-mini rules v4]
Todoist MCP:
- For a general overview, call get-overview without projectId.
- For a specific project, call find-projects first and use only the returned real ID.
- For Inbox processing, find the real Inbox project, then call find-tasks with that project ID. Labels and overview are optional and must not block task processing.
- Omit optional arguments unless they are needed. Never send null, an empty string, a guessed ID, or a guessed cursor. Pass cursor only when the preceding response returned a non-empty cursor.
- INVALID_ARGUMENT_VALUE identifies a bad argument. Read the named argument from the error, remove or correct it, and do not repeat the same call with the same arguments.
- One tool argument error does not mean Todoist is unavailable. Continue with narrower calls that do not need the failing optional data.
- If the MCP circuit breaker opens, wait for its roughly 60-second cooldown and retry once with corrected arguments. Only report an outage if that corrected retry also fails with a connection, timeout, or server error.
- A short-lived access token is normal because Hermes refreshes it automatically. Never force OAuth only because the access token is about one hour old.
- Use `hermes mcp login todoist --force` only for invalid_grant, needs_reauth, or an intentional account/scope change. The hermes-setup wrapper restores previous credentials if the new flow fails.
MCP lifecycle:
- After adding or changing an MCP server, run /reload-mcp for the active gateway session or restart the gateway before concluding that the agent cannot see its tools.
Obsidian:
- For Obsidian vault administration, load the `obsidian-para` skill and follow it instead of the built-in filesystem-first Obsidian workflow.
- Access vault content only through the scoped MCP server named `obsidian`. Do not use terminal, generic file tools, or direct filesystem paths as a fallback.
- If the `obsidian` MCP is unavailable, report the limitation and do not bypass its scope.
"""


def remove_managed_rules(prompt: str) -> str:
    markers = (RULE_MARKER, *LEGACY_RULE_MARKERS)
    starts = [prompt.find(marker) for marker in markers if marker in prompt]
    if not starts:
        return prompt.rstrip()

    start = min(starts)
    return prompt[:start].rstrip()


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
        base = remove_managed_rules(current)
        prompts[chat_id] = f"{base}\n\n{RULE_TEXT}".strip()

    config_path.write_text(
        yaml.safe_dump(config, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
