#!/usr/bin/env python3

import importlib.util
import io
import inspect
import json
import os
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from types import ModuleType
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/vps/yandex-speechkit-stt.py"


def load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("yandex_speechkit_stt", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class YandexSpeechKitPayloadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(SCRIPT.is_file(), f"missing implementation: {SCRIPT}")
        self.module = load_module()

    def test_build_payload_embeds_ogg_opus_and_russian_language(self) -> None:
        payload = self.module.build_payload(b"opus", "ru", "general", ".ogg")

        self.assertEqual(payload["content"], "b3B1cw==")
        recognition = payload["recognitionModel"]
        self.assertEqual(recognition["model"], "general")
        self.assertEqual(
            recognition["audioFormat"]["containerAudio"]["containerAudioType"],
            "OGG_OPUS",
        )
        self.assertEqual(
            recognition["textNormalization"]["textNormalization"],
            "TEXT_NORMALIZATION_ENABLED",
        )
        self.assertEqual(
            recognition["languageRestriction"],
            {"restrictionType": "WHITELIST", "languageCode": ["ru-RU"]},
        )

    def test_build_payload_rejects_unsupported_container(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported audio format"):
            self.module.build_payload(b"audio", "ru", "general", ".aac")

    def test_decode_events_accepts_result_wrappers_and_json_lines(self) -> None:
        raw = b"\n".join(
            [
                json.dumps({"result": {"final": {"alternatives": [{"text": "one"}]}}}).encode(),
                json.dumps({"result": {"final": {"alternatives": [{"text": "two"}]}}}).encode(),
            ]
        )

        events = self.module.decode_events(raw)

        self.assertEqual([item["final"]["alternatives"][0]["text"] for item in events], ["one", "two"])

    def test_extract_transcript_prefers_normalized_refinements(self) -> None:
        events = [
            {"final": {"alternatives": [{"text": "привет мир"}]}},
            {
                "finalRefinement": {
                    "finalIndex": "0",
                    "normalizedText": {
                        "alternatives": [{"text": "Привет, мир."}]
                    },
                }
            },
        ]

        self.assertEqual(self.module.extract_transcript(events), "Привет, мир.")

    def test_extract_transcript_joins_raw_finals_without_refinement(self) -> None:
        events = [
            {"final": {"alternatives": [{"text": "первая фраза"}]}},
            {"final": {"alternatives": [{"text": "вторая фраза"}]}},
        ]

        self.assertEqual(
            self.module.extract_transcript(events),
            "первая фраза вторая фраза",
        )

    def test_extract_transcript_rejects_empty_response(self) -> None:
        with self.assertRaisesRegex(ValueError, "no final transcript"):
            self.module.extract_transcript([{"statusCode": {"codeType": "CLOSED"}}])


class FakeResponse:
    def __init__(self, body: object) -> None:
        self.body = body if isinstance(body, bytes) else json.dumps(body).encode()

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body


class SequenceOpener:
    def __init__(self, *responses: object) -> None:
        self.responses = list(responses)
        self.requests: list[object] = []

    def __call__(self, request: object, timeout: float) -> FakeResponse:
        self.requests.append(request)
        if not self.responses:
            raise AssertionError("unexpected HTTP request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return FakeResponse(response)


class YandexSpeechKitAsyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(SCRIPT.is_file(), f"missing implementation: {SCRIPT}")
        self.module = load_module()
        self.assertTrue(
            hasattr(self.module, "transcribe"),
            "SpeechKit adapter must expose transcribe()",
        )

    def test_transcribe_waits_for_operation_and_reads_final_result(self) -> None:
        events = b"\n".join(
            [
                json.dumps({"result": {"final": {"alternatives": [{"text": "сырой текст"}]}}}).encode(),
                json.dumps(
                    {
                        "result": {
                            "finalRefinement": {
                                "finalIndex": "0",
                                "normalizedText": {
                                    "alternatives": [{"text": "Готовый текст."}]
                                },
                            }
                        }
                    }
                ).encode(),
            ]
        )
        opener = SequenceOpener(
            {"id": "operation-1", "done": False},
            {"id": "operation-1", "done": False},
            {"id": "operation-1", "done": True, "response": {}},
            events,
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            audio = Path(temp_dir) / "voice.ogg"
            audio.write_bytes(b"opus")
            text = self.module.transcribe(
                audio,
                api_key="secret-key",
                folder_id="b1gfolder",
                language="ru",
                model="general",
                timeout=30,
                opener=opener,
                sleeper=lambda _delay: None,
                clock=lambda: 0.0,
            )

        self.assertEqual(text, "Готовый текст.")
        self.assertEqual(len(opener.requests), 4)
        first = opener.requests[0]
        self.assertEqual(first.full_url, self.module.RECOGNIZE_URL)
        self.assertEqual(first.headers["Authorization"], "Api-Key secret-key")
        self.assertEqual(first.headers["X-folder-id"], "b1gfolder")
        self.assertIn(b'"containerAudioType": "OGG_OPUS"', first.data)
        self.assertTrue(opener.requests[-1].full_url.endswith("operationId=operation-1"))

    def test_transcribe_times_out_after_configured_deadline(self) -> None:
        opener = SequenceOpener(
            {"id": "operation-2", "done": False},
            {"id": "operation-2", "done": False},
        )
        times = iter([0.0, 2.0])
        with tempfile.TemporaryDirectory() as temp_dir:
            audio = Path(temp_dir) / "voice.ogg"
            audio.write_bytes(b"opus")
            with self.assertRaisesRegex(TimeoutError, "exceeded 1s"):
                self.module.transcribe(
                    audio,
                    api_key="secret-key",
                    folder_id="b1gfolder",
                    language="ru",
                    model="general",
                    timeout=1,
                    opener=opener,
                    sleeper=lambda _delay: None,
                    clock=lambda: next(times),
                )

    def test_request_json_retries_rate_limits_and_server_errors(self) -> None:
        self.assertIn(
            "sleeper",
            inspect.signature(self.module.request_json).parameters,
            "request_json() must expose retry delay injection",
        )
        headers = {
            "Authorization": "Api-Key secret-key",
            "Content-Type": "application/json",
        }
        for status in (429, 503):
            with self.subTest(status=status):
                error = urllib.error.HTTPError(
                    "https://example.test",
                    status,
                    "transient",
                    {},
                    io.BytesIO(b'{"message":"retry"}'),
                )
                opener = SequenceOpener(error, {"ok": True})
                delays: list[float] = []
                try:
                    result = self.module.request_json(
                        "https://example.test",
                        headers,
                        {"ping": True},
                        opener,
                        sleeper=delays.append,
                    )
                except RuntimeError as exc:
                    self.fail(f"transient HTTP {status} was not retried: {exc}")

                self.assertEqual(result, {"ok": True})
                self.assertEqual(delays, [1.0])

    def test_request_json_redacts_api_key_from_http_error(self) -> None:
        error = urllib.error.HTTPError(
            "https://example.test",
            401,
            "unauthorized",
            {},
            io.BytesIO(b'{"message":"bad secret-key"}'),
        )
        headers = {
            "Authorization": "Api-Key secret-key",
            "Content-Type": "application/json",
        }

        with self.assertRaises(RuntimeError) as captured:
            self.module.request_json(
                "https://example.test",
                headers,
                {"ping": True},
                SequenceOpener(error),
            )

        self.assertNotIn("secret-key", str(captured.exception))
        self.assertIn("[REDACTED]", str(captured.exception))

    def test_main_preserves_whisper_cli_contract(self) -> None:
        calls: list[tuple] = []

        def fake_transcriber(*args: object, **kwargs: object) -> str:
            calls.append((args, kwargs))
            return "Распознанный текст."

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            audio = root / "telegram.ogg"
            output = root / "output"
            audio.write_bytes(b"opus")
            stdout = io.StringIO()
            env = {
                "YANDEX_API_KEY": "secret-key",
                "YANDEX_FOLDER_ID": "b1gfolder",
                "HERMES_YANDEX_STT_MODEL": "general",
                "HERMES_YANDEX_STT_TIMEOUT": "45",
            }
            argv = [
                str(audio),
                "--model",
                "base",
                "--language",
                "ru",
                "--output_dir",
                str(output),
                "--output_format",
                "txt",
            ]
            with patch.dict(os.environ, env, clear=True), redirect_stdout(stdout):
                status = self.module.main(argv, transcriber=fake_transcriber)

            self.assertEqual(status, 0)
            self.assertEqual(stdout.getvalue(), "Распознанный текст.\n")
            self.assertEqual(
                (output / "telegram.txt").read_text(encoding="utf-8"),
                "Распознанный текст.\n",
            )
            self.assertEqual(calls[0][0][1:6], ("secret-key", "b1gfolder", "ru", "general", 45.0))


if __name__ == "__main__":
    unittest.main()
