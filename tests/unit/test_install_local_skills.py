#!/usr/bin/env python3

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/macos/install-local-skills.py"


class InstallLocalSkillsTest(unittest.TestCase):
    def test_installs_enabled_local_skill_idempotently(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            repo = root / "repo"
            source = repo / "skills" / "example"
            source.mkdir(parents=True)
            (source / "SKILL.md").write_text(
                "---\nname: example\ndescription: Test skill.\n---\n",
                encoding="utf-8",
            )
            config = repo / "skills.toml"
            config.write_text(
                '[example]\nenabled = true\ntype = "local"\n'
                'source = "skills/example"\n',
                encoding="utf-8",
            )
            hermes_home = root / "home"
            command = [
                sys.executable,
                str(SCRIPT),
                "--repo-root",
                str(repo),
                "--config",
                str(config),
                "--hermes-home",
                str(hermes_home),
            ]

            first = subprocess.run(command, check=True, text=True, capture_output=True)
            second = subprocess.run(command, check=True, text=True, capture_output=True)

            self.assertIn("installed: skill.example", first.stdout)
            self.assertIn("unchanged: skill.example", second.stdout)
            self.assertTrue((hermes_home / "skills/example/SKILL.md").is_file())


if __name__ == "__main__":
    unittest.main()
