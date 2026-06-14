"""OpenRouter image generation provider for Hermes."""

from __future__ import annotations

import os
from typing import Any, Dict, List, Optional

import requests

from agent.image_gen_provider import (
    DEFAULT_ASPECT_RATIO,
    ImageGenProvider,
    error_response,
    resolve_aspect_ratio,
    save_b64_image,
    save_url_image,
    success_response,
)


DEFAULT_MODEL = "google/gemini-2.5-flash-image"
MODELS = (
    ("google/gemini-2.5-flash-image", "Nano Banana", "Fast low-cost generation"),
    ("google/gemini-3.1-flash-image-preview", "Nano Banana 2", "Higher-quality fast generation"),
    ("openai/gpt-5-image-mini", "GPT-5 Image Mini", "OpenAI image generation"),
    ("black-forest-labs/flux.2-klein-4b", "FLUX.2 Klein", "Fast open image model"),
)


def _api_key() -> str:
    return os.environ.get("OPENROUTER_API_KEY", "").strip()


def _model() -> str:
    return os.environ.get("HERMES_OPENROUTER_IMAGE_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL


def _extract_image(result: dict) -> tuple[str, str]:
    choices = result.get("choices") or []
    if not choices:
        raise ValueError("OpenRouter returned no choices")
    images = (choices[0].get("message") or {}).get("images") or []
    if not images:
        raise ValueError("OpenRouter response contained no generated image")
    first = images[0]
    value = first if isinstance(first, str) else first.get("image_url") or first.get("url")
    if isinstance(value, dict):
        value = value.get("url")
    if not isinstance(value, str) or not value:
        raise ValueError("OpenRouter returned an unsupported image response")
    if value.startswith("data:image/") and ";base64," in value:
        header, payload = value.split(",", 1)
        extension = header.split("/", 1)[1].split(";", 1)[0]
        return payload, extension
    return value, ""


class OpenRouterImageProvider(ImageGenProvider):
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
            {"id": model, "display": display, "strengths": strengths}
            for model, display, strengths in MODELS
        ]

    def default_model(self) -> Optional[str]:
        return DEFAULT_MODEL

    def generate(
        self,
        prompt: str,
        aspect_ratio: str = DEFAULT_ASPECT_RATIO,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        prompt = (prompt or "").strip()
        aspect = resolve_aspect_ratio(aspect_ratio)
        model = str(kwargs.get("model") or _model())
        if not prompt:
            return error_response(
                error="Prompt is required", error_type="invalid_input",
                provider=self.name, model=model, aspect_ratio=aspect,
            )
        if not _api_key():
            return error_response(
                error="OPENROUTER_API_KEY is not configured",
                error_type="missing_api_key", provider=self.name,
                model=model, prompt=prompt, aspect_ratio=aspect,
            )
        ratios = {"landscape": "16:9", "square": "1:1", "portrait": "9:16"}
        try:
            response = requests.post(
                "https://openrouter.ai/api/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {_api_key()}",
                    "Content-Type": "application/json",
                    "HTTP-Referer": "https://github.com/RudinMaxim/hermes-setup",
                    "X-Title": "Hermes Agent",
                },
                json={
                    "model": model,
                    "messages": [{"role": "user", "content": prompt}],
                    "modalities": ["image", "text"],
                    "image_config": {"aspect_ratio": ratios[aspect]},
                },
                timeout=240,
            )
            response.raise_for_status()
            value, extension = _extract_image(response.json())
            if extension:
                path = save_b64_image(
                    value, prefix="openrouter",
                    extension="jpg" if extension == "jpeg" else extension,
                )
            else:
                path = save_url_image(value, prefix="openrouter")
            return success_response(
                image=str(path), model=model, prompt=prompt,
                aspect_ratio=aspect, provider=self.name,
            )
        except requests.Timeout:
            error, error_type = "OpenRouter image generation timed out", "timeout"
        except requests.HTTPError as exc:
            detail = exc.response.text[:500] if exc.response is not None else str(exc)
            error, error_type = f"OpenRouter image generation failed: {detail}", "api_error"
        except (requests.RequestException, ValueError, KeyError) as exc:
            error, error_type = f"OpenRouter image generation failed: {exc}", "provider_error"
        return error_response(
            error=error, error_type=error_type, provider=self.name,
            model=model, prompt=prompt, aspect_ratio=aspect,
        )


def register(ctx: Any) -> None:
    ctx.register_image_gen_provider(OpenRouterImageProvider())
