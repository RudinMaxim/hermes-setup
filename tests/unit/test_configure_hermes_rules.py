#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/macos/configure-hermes-rules.py"


class ConfigureHermesRulesTest(unittest.TestCase):
    def test_replaces_v2_rules_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            hermes_home = Path(temp_dir)
            config_path = hermes_home / "config.yaml"
            config_path.write_text(
                yaml.safe_dump(
                    {
                        "telegram": {
                            "allowed_chats": "123",
                            "channel_prompts": {
                                "123": (
                                    "Keep this custom prompt.\n\n"
                                    "[hermes-setup mac-mini rules v2]\n"
                                    "Todoist MCP:\n"
                                    "- stale rule\n"
                                )
                            },
                        }
                    },
                    sort_keys=False,
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["HERMES_HOME"] = str(hermes_home)

            subprocess.run([sys.executable, str(SCRIPT)], check=True, env=env)
            first = config_path.read_text(encoding="utf-8")
            subprocess.run([sys.executable, str(SCRIPT)], check=True, env=env)
            second = config_path.read_text(encoding="utf-8")
            prompt = yaml.safe_load(first)["telegram"]["channel_prompts"]["123"]

            self.assertEqual(first, second)
            self.assertIn("Keep this custom prompt.", prompt)
            self.assertNotIn("rules v2", prompt)
            self.assertEqual(prompt.count("[hermes-setup mac-mini rules v5]"), 1)
            self.assertIn("Never send null, an empty string", prompt)
            self.assertIn("load the `obsidian-para` skill", prompt)
            self.assertIn("load both `google-calendar-os` and `todoist-os`", prompt)


if __name__ == "__main__":
    unittest.main()
