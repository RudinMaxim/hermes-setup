"""OpenRouter video generation provider for Hermes."""

from __future__ import annotations

import os
import time
from typing import Any, Dict, List, Optional

import requests

from agent.video_gen_provider import (
    DEFAULT_ASPECT_RATIO,
    DEFAULT_RESOLUTION,
    VideoGenProvider,
    error_response,
    save_bytes_video,
    success_response,
)


DEFAULT_MODEL = "google/veo-3.1-lite"
MODELS = (
    ("google/veo-3.1-lite", "Veo 3.1 Lite", "Lower-cost general generation"),
    ("google/veo-3.1-fast", "Veo 3.1 Fast", "Faster Veo generation"),
    ("bytedance/seedance-2.0-fast", "Seedance 2.0 Fast", "Fast text and image animation"),
    ("x-ai/grok-imagine-video", "Grok Imagine Video", "xAI video generation"),
)
TERMINAL_STATUSES = {"completed", "failed", "cancelled", "expired"}


def _api_key() -> str:
    return os.environ.get("OPENROUTER_API_KEY", "").strip()


def _model() -> str:
    return os.environ.get("HERMES_OPENROUTER_VIDEO_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL


def _headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {_api_key()}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/RudinMaxim/hermes-setup",
        "X-Title": "Hermes Agent",
    }


class OpenRouterVideoProvider(VideoGenProvider):
    @property
    def name(self) -> str:
        return "openrouter"

    @property
    def display_name(self) -> str:
        return "OpenRouter"

    def is_available(self) -> bool:
        return bool(_api_key())

    def list_models(self) -> List[Dict[str, Any]]:
        return [
            {
                "id": model, "display": display, "strengths": strengths,
                "modalities": ["text", "image"],
            }
            for model, display, strengths in MODELS
        ]

    def default_model(self) -> Optional[str]:
        return DEFAULT_MODEL

    def capabilities(self) -> Dict[str, Any]:
        return {
            "modalities": ["text", "image"],
            "aspect_ratios": ["16:9", "9:16", "1:1"],
            "resolutions": ["720p", "1080p"],
            "max_duration": 10,
            "min_duration": 4,
            "supports_audio": True,
            "supports_negative_prompt": False,
            "max_reference_images": 1,
        }

    def generate(
        self,
        prompt: str,
        *,
        model: Optional[str] = None,
        image_url: Optional[str] = None,
        reference_image_urls: Optional[List[str]] = None,
        duration: Optional[int] = None,
        aspect_ratio: str = DEFAULT_ASPECT_RATIO,
        resolution: str = DEFAULT_RESOLUTION,
        audio: Optional[bool] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        del reference_image_urls, kwargs
        prompt = (prompt or "").strip()
        selected_model = model or _model()
        modality = "image" if image_url else "text"
        if not prompt:
            return error_response(
                error="Prompt is required", error_type="invalid_input",
                provider=self.name, model=selected_model,
            )
        if not _api_key():
            return error_response(
                error="OPENROUTER_API_KEY is not configured",
                error_type="missing_api_key", provider=self.name,
                model=selected_model, prompt=prompt,
            )
        payload: Dict[str, Any] = {
            "model": selected_model,
            "prompt": prompt,
            "duration": max(4, min(int(duration or 5), 10)),
            "aspect_ratio": aspect_ratio if aspect_ratio in {"16:9", "9:16", "1:1"} else "16:9",
            "resolution": resolution if resolution in {"720p", "1080p"} else "720p",
            "generate_audio": True if audio is None else bool(audio),
        }
        if image_url:
            payload["frame_images"] = [
                {
                    "type": "image_url",
                    "image_url": {"url": image_url},
                    "frame_type": "first_frame",
                }
            ]
        try:
            response = requests.post(
                "https://openrouter.ai/api/v1/videos",
                headers=_headers(), json=payload, timeout=60,
            )
            response.raise_for_status()
            request_id = response.json().get("id")
            if not request_id:
                raise ValueError("OpenRouter returned no video request id")
            deadline = time.monotonic() + 900
            result: dict = {}
            while time.monotonic() < deadline:
                status_response = requests.get(
                    f"https://openrouter.ai/api/v1/videos/{request_id}",
                    headers=_headers(), timeout=60,
                )
                status_response.raise_for_status()
                result = status_response.json()
                if str(result.get("status") or "").lower() in TERMINAL_STATUSES:
                    break
                time.sleep(30)
            else:
                raise TimeoutError("OpenRouter video generation timed out")
            if str(result.get("status") or "").lower() != "completed":
                raise ValueError(
                    result.get("error") or result.get("message")
                    or f"video ended with status {result.get('status')}"
                )
            content = requests.get(
                f"https://openrouter.ai/api/v1/videos/{request_id}/content",
                headers=_headers(), timeout=180,
            )
            content.raise_for_status()
            path = save_bytes_video(content.content, prefix="openrouter", extension="mp4")
            return success_response(
                video=str(path), model=selected_model, prompt=prompt,
                modality=modality, aspect_ratio=payload["aspect_ratio"],
                duration=payload["duration"], provider=self.name,
                extra={"request_id": request_id, "resolution": payload["resolution"]},
            )
        except requests.Timeout:
            error, error_type = "OpenRouter video request timed out", "timeout"
        except TimeoutError as exc:
            error, error_type = str(exc), "timeout"
        except requests.HTTPError as exc:
            detail = exc.response.text[:500] if exc.response is not None else str(exc)
            error, error_type = f"OpenRouter video generation failed: {detail}", "api_error"
        except (requests.RequestException, ValueError, KeyError) as exc:
            error, error_type = f"OpenRouter video generation failed: {exc}", "provider_error"
        return error_response(
            error=error, error_type=error_type, provider=self.name,
            model=selected_model, prompt=prompt, aspect_ratio=aspect_ratio,
        )


def register(ctx: Any) -> None:
    ctx.register_video_gen_provider(OpenRouterVideoProvider())
