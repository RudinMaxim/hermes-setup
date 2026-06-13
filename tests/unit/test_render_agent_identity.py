#!/usr/bin/env python3

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/macos/render-agent-identity.py"


class RenderAgentIdentityTest(unittest.TestCase):
    def test_preview_and_apply_with_backup(self) -> None:
        profile = {
            "assistant": {
                "name": "Test Assistant",
                "role": "Operational partner",
                "tone": {"directness": 4, "warmth": 3, "formality": 2, "verbosity": 2},
                "defaults": {"admit_uncertainty": True},
            },
            "user": {
                "name": "Max",
                "address_as": "Max",
                "language": "ru",
                "timezone": "Asia/Yekaterinburg",
            },
            "environment": {
                "os": "macOS",
                "shell": "zsh",
                "stable_facts": ["Todoist is the action system."],
            },
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            profile_path = root / "profile.yaml"
            profile_path.write_text(yaml.safe_dump(profile), encoding="utf-8")
            home = root / "home"
            (home / "memories").mkdir(parents=True)
            (home / "SOUL.md").write_text("old soul\n", encoding="utf-8")

            preview = subprocess.run(
                [sys.executable, str(SCRIPT), "--profile", str(profile_path)],
                check=True,
                text=True,
                capture_output=True,
            )
            self.assertIn("===== SOUL.md", preview.stdout)
            self.assertIn("Test Assistant", preview.stdout)

            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--profile",
                    str(profile_path),
                    "--hermes-home",
                    str(home),
                    "--apply",
                ],
                check=True,
            )
            self.assertIn("Test Assistant", (home / "SOUL.md").read_text())
            self.assertIn("Name: Max", (home / "memories/USER.md").read_text())
            backups = list((home / "backups/identity").glob("*/SOUL.md"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), "old soul\n")


if __name__ == "__main__":
    unittest.main()
