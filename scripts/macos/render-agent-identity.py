#!/usr/bin/env python3
"""Render SOUL.md, USER.md, and MEMORY.md from a reviewed YAML profile."""

from __future__ import annotations

import argparse
import shutil
from datetime import datetime, timezone
from pathlib import Path

import yaml


LIMITS = {"USER.md": 1375, "MEMORY.md": 2200}


def compact(items: list[str]) -> str:
    return "; ".join(str(item).strip() for item in items if str(item).strip())


def render_soul(profile: dict) -> str:
    assistant = profile.get("assistant") or {}
    tone = assistant.get("tone") or {}
    defaults = assistant.get("defaults") or {}
    avoid = assistant.get("avoid") or []
    examples = assistant.get("examples") or {}
    lines = [
        f"# Identity\n\nYou are {assistant.get('name', 'a personal assistant')}.",
        str(assistant.get("role") or "").strip(),
        str(assistant.get("relationship") or "").strip(),
        "\n# Style",
        f"- Directness: {tone.get('directness', 3)}/5",
        f"- Warmth: {tone.get('warmth', 3)}/5",
        f"- Formality: {tone.get('formality', 3)}/5",
        f"- Verbosity: {tone.get('verbosity', 3)}/5",
    ]
    labels = {
        "challenge_weak_assumptions": "Challenge weak assumptions directly.",
        "distinguish_fact_inference_opinion": "Distinguish facts, inferences, and opinions.",
        "admit_uncertainty": "Admit uncertainty instead of inventing confidence.",
        "ask_when_risk_is_material": "Ask when missing information creates material risk.",
        "act_without_reconfirmation_for_read_only_work": "Proceed autonomously with safe read-only work.",
    }
    lines.extend(text for key, text in labels.items() if defaults.get(key))
    if avoid:
        lines.extend(["\n# Avoid", *(f"- {item}" for item in avoid)])
    good = examples.get("good") or []
    bad = examples.get("bad") or []
    if good or bad:
        lines.append("\n# Examples")
        for item in good:
            lines.append(
                f"- Good: User: {item.get('user', '')} Assistant: {item.get('assistant', '')}"
            )
        for item in bad:
            lines.append(
                f"- Avoid: User: {item.get('user', '')} Assistant: {item.get('assistant', '')}"
            )
    return "\n".join(line for line in lines if line).strip() + "\n"


def render_user(profile: dict) -> str:
    user = profile.get("user") or {}
    communication = user.get("communication") or {}
    entries = [
        compact(
            [
                f"Name: {user.get('name', '')}",
                f"address as: {user.get('address_as', '')}",
                f"language: {user.get('language', '')}",
                f"timezone: {user.get('timezone', '')}",
            ]
        ),
        f"Roles: {compact(user.get('roles') or [])}",
        f"Long-term goals: {compact(user.get('goals') or [])}",
        compact(
            [
                f"Response length: {communication.get('preferred_length', '')}",
                f"format: {communication.get('preferred_format', '')}",
                f"corrections: {communication.get('correction_style', '')}",
            ]
        ),
        f"Decision style: {user.get('decision_style', '')}",
        f"Working style: {user.get('working_style', '')}",
        f"Recurring constraints: {compact(user.get('recurring_constraints') or [])}",
        f"Dislikes: {compact(user.get('dislikes') or [])}",
    ]
    return "\n§\n".join(entry for entry in entries if entry.rsplit(": ", 1)[-1].strip()) + "\n"


def render_memory(profile: dict) -> str:
    environment = profile.get("environment") or {}
    entries = [
        compact(
            [
                f"OS: {environment.get('os', '')}",
                f"shell: {environment.get('shell', '')}",
                f"primary repo: {environment.get('primary_repo', '')}",
            ]
        ),
        *(environment.get("stable_facts") or []),
        *(environment.get("tool_rules") or []),
    ]
    return "\n§\n".join(str(entry).strip() for entry in entries if str(entry).strip()) + "\n"


def validate(name: str, content: str) -> None:
    limit = LIMITS.get(name)
    if limit and len(content) > limit:
        raise ValueError(f"{name} is {len(content)} chars; Hermes limit is {limit}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--hermes-home", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    profile = yaml.safe_load(args.profile.read_text(encoding="utf-8")) or {}
    rendered = {
        "SOUL.md": render_soul(profile),
        "USER.md": render_user(profile),
        "MEMORY.md": render_memory(profile),
    }
    for name, content in rendered.items():
        validate(name, content)

    if not args.apply:
        for name, content in rendered.items():
            print(f"===== {name} ({len(content)} chars) =====")
            print(content)
        return

    if args.hermes_home is None:
        parser.error("--hermes-home is required with --apply")

    home = args.hermes_home.expanduser()
    memories = home / "memories"
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    backup = home / "backups" / "identity" / timestamp
    targets = {
        "SOUL.md": home / "SOUL.md",
        "USER.md": memories / "USER.md",
        "MEMORY.md": memories / "MEMORY.md",
    }
    for target in targets.values():
        if target.exists():
            relative = target.relative_to(home)
            destination = backup / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, destination)
    memories.mkdir(parents=True, exist_ok=True)
    for name, target in targets.items():
        target.write_text(rendered[name], encoding="utf-8")
    print(f"Applied identity profile; backup: {backup}")


if __name__ == "__main__":
    main()
