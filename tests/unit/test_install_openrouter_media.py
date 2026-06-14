#!/usr/bin/env python3

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/macos/install-openrouter-media.py"


class InstallOpenRouterMediaTest(unittest.TestCase):
    def test_installs_plugins_and_preserves_other_enabled_plugins(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            (home / "config.yaml").write_text(
                yaml.safe_dump({"plugins": {"enabled": ["existing"]}}),
                encoding="utf-8",
            )
            command = [
                sys.executable, str(SCRIPT),
                "--repo-root", str(REPO_ROOT),
                "--hermes-home", str(home),
                "--image-model", "image-test",
                "--video-model", "video-test",
            ]
            subprocess.run(command, check=True)
            subprocess.run(command, check=True)

            config = yaml.safe_load((home / "config.yaml").read_text())
            self.assertEqual(
                config["plugins"]["enabled"],
                ["existing", "image_gen/openrouter", "video_gen/openrouter"],
            )
            self.assertEqual(config["image_gen"]["provider"], "openrouter")
            self.assertEqual(config["image_gen"]["model"], "image-test")
            self.assertEqual(config["video_gen"]["provider"], "openrouter")
            self.assertTrue(
                (home / "plugins/image_gen/openrouter/plugin.yaml").is_file()
            )


if __name__ == "__main__":
    unittest.main()
