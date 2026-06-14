#!/usr/bin/env python3

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


REPO_ROOT = Path(__file__).resolve().parents[2]


def load_plugin(category: str):
    path = REPO_ROOT / "plugins" / category / "openrouter" / "__init__.py"
    spec = importlib.util.spec_from_file_location(f"test_{category}_openrouter", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


class OpenRouterMediaTest(unittest.TestCase):
    def setUp(self) -> None:
        self.old_home = os.environ.get("HERMES_HOME")
        self.old_key = os.environ.get("OPENROUTER_API_KEY")
        self.temp_dir = tempfile.TemporaryDirectory()
        os.environ["HERMES_HOME"] = self.temp_dir.name
        os.environ["OPENROUTER_API_KEY"] = "test-key"

    def tearDown(self) -> None:
        self.temp_dir.cleanup()
        if self.old_home is None:
            os.environ.pop("HERMES_HOME", None)
        else:
            os.environ["HERMES_HOME"] = self.old_home
        if self.old_key is None:
            os.environ.pop("OPENROUTER_API_KEY", None)
        else:
            os.environ["OPENROUTER_API_KEY"] = self.old_key

    def test_image_provider_saves_data_uri(self) -> None:
        module = load_plugin("image_gen")
        response = Mock()
        response.raise_for_status.return_value = None
        response.json.return_value = {
            "choices": [{
                "message": {
                    "images": [{
                        "type": "image_url",
                        "image_url": {"url": "data:image/png;base64,iVBORw0KGgo="},
                    }]
                }
            }]
        }
        with patch.object(module.requests, "post", return_value=response):
            result = module.OpenRouterImageProvider().generate("red square", "square")
        self.assertTrue(result["success"])
        self.assertTrue(Path(result["image"]).is_file())

    def test_video_provider_polls_and_saves_content(self) -> None:
        module = load_plugin("video_gen")
        submit = Mock()
        submit.raise_for_status.return_value = None
        submit.json.return_value = {"id": "video-1"}
        status = Mock()
        status.raise_for_status.return_value = None
        status.json.return_value = {"id": "video-1", "status": "completed"}
        content = Mock()
        content.raise_for_status.return_value = None
        content.content = b"fake-mp4"
        with (
            patch.object(module.requests, "post", return_value=submit) as mocked_post,
            patch.object(module.requests, "get", side_effect=[status, content]),
        ):
            result = module.OpenRouterVideoProvider().generate(
                "moving red square",
                image_url="https://example.com/frame.png",
            )
        self.assertTrue(result["success"])
        self.assertEqual(Path(result["video"]).read_bytes(), b"fake-mp4")
        payload = mocked_post.call_args.kwargs["json"]
        self.assertTrue(payload["generate_audio"])
        self.assertEqual(
            payload["frame_images"][0]["image_url"]["url"],
            "https://example.com/frame.png",
        )


if __name__ == "__main__":
    unittest.main()
