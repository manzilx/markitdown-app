"""Validation and normalization for OCR export payloads."""

from __future__ import annotations

import math
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

MAX_EXPORT_PAGES = 10_000
MAX_BLOCKS_PER_PAGE = 50_000
MAX_EXPORT_JSON_BYTES = 10 * 1024 * 1024
MAX_PAGE_TEXT_CHARS = 2_000_000
MAX_BLOCK_TEXT_CHARS = 100_000


class ExportPayloadError(Exception):
    pass


class ExportBlockPayload(BaseModel):
    model_config = ConfigDict(extra="ignore")

    text: str = Field(default="", max_length=MAX_BLOCK_TEXT_CHARS)
    confidence: float | None = None
    bbox_normalized: list[float] | None = None
    is_redacted: bool = False

    @field_validator("text", mode="before")
    @classmethod
    def normalize_text(cls, value: Any) -> str:
        if value is None:
            return ""
        return str(value)

    @field_validator("confidence", mode="before")
    @classmethod
    def normalize_confidence(cls, value: Any) -> float | None:
        if value in (None, ""):
            return None
        try:
            confidence = float(value)
        except (TypeError, ValueError):
            return None
        return confidence if math.isfinite(confidence) else None

    @field_validator("bbox_normalized", mode="before")
    @classmethod
    def normalize_bbox(cls, value: Any) -> list[float] | None:
        if value in (None, ""):
            return None
        if not isinstance(value, (list, tuple)) or len(value) != 4:
            return None

        try:
            min_x, min_y, width, height = (float(part) for part in value)
        except (TypeError, ValueError):
            return None

        parts = [min_x, min_y, width, height]
        if not all(math.isfinite(part) for part in parts):
            return None
        if width <= 0 or height <= 0:
            return None

        return parts


class ExportPagePayload(BaseModel):
    model_config = ConfigDict(extra="ignore")

    page_number: int = Field(ge=1)
    ocr_text: str = Field(default="", max_length=MAX_PAGE_TEXT_CHARS)
    edited_text: str | None = Field(default=None, max_length=MAX_PAGE_TEXT_CHARS)
    export_text: str | None = Field(default=None, max_length=MAX_PAGE_TEXT_CHARS)
    blocks: list[ExportBlockPayload] = Field(default_factory=list, max_length=MAX_BLOCKS_PER_PAGE)

    @field_validator("ocr_text", mode="before")
    @classmethod
    def normalize_required_text(cls, value: Any) -> str:
        if value is None:
            return ""
        return str(value)

    @field_validator("edited_text", "export_text", mode="before")
    @classmethod
    def normalize_optional_text(cls, value: Any) -> str | None:
        if value is None:
            return None
        return str(value)


def normalize_export_pages(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise ExportPayloadError("pages_json must be a non-empty array")
    if len(value) > MAX_EXPORT_PAGES:
        raise ExportPayloadError(f"pages_json cannot contain more than {MAX_EXPORT_PAGES} pages")

    pages: list[dict[str, Any]] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise ExportPayloadError(f"Invalid page at index {index}: expected object")
        try:
            page = ExportPagePayload.model_validate(item)
        except ValidationError as exc:
            first_error = exc.errors()[0] if exc.errors() else {}
            field = ".".join(str(part) for part in first_error.get("loc", ())) or "page"
            message = first_error.get("msg", "invalid value")
            raise ExportPayloadError(f"Invalid page at index {index}: {field} {message}") from exc
        pages.append(page.model_dump(mode="json"))

    return pages
