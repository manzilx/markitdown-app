"""Environment-driven configuration for MarkItDown engines."""

from __future__ import annotations

import os
from dataclasses import dataclass
from enum import Enum
from functools import lru_cache
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

# Load ~/markitdown-app/.env when the API starts (repo root = api/../)
_PROJECT_ROOT = Path(__file__).resolve().parents[2]
load_dotenv(_PROJECT_ROOT / ".env")


class Engine(str, Enum):
    BUILTIN = "builtin"
    AZURE_DOC_INTEL = "azure_doc_intel"
    PYMUPDF4LLM = "pymupdf4llm"
    OCR_PLUGIN = "ocr_plugin"


MAX_UPLOAD_BYTES = 25 * 1024 * 1024
MAX_MULTIPART_PART_BYTES = 100 * 1024 * 1024

IMAGE_EXTENSIONS = {
    ".png",
    ".jpg",
    ".jpeg",
    ".tif",
    ".tiff",
    ".heic",
}

ALLOWED_EXTENSIONS = {
    ".pdf",
    ".docx",
    ".pptx",
    ".xlsx",
    ".xls",
    ".csv",
    ".json",
    ".xml",
    ".html",
    ".htm",
    ".txt",
    ".md",
    ".zip",
    ".epub",
} | IMAGE_EXTENSIONS

PAGE_IMAGE_OCR_ENGINES = {
    Engine.AZURE_DOC_INTEL,
    Engine.OCR_PLUGIN,
}

ENGINE_META: dict[Engine, dict[str, str]] = {
    Engine.BUILTIN: {
        "label": "Built-in (local)",
        "description": "pdfplumber + pdfminer for searchable PDFs and office docs.",
        "badge": "",
    },
    Engine.AZURE_DOC_INTEL: {
        "label": "Azure Document Intelligence",
        "description": "Cloud layout + high-res OCR for scans and complex documents.",
        "badge": "Cloud · billed per page",
    },
    Engine.PYMUPDF4LLM: {
        "label": "PyMuPDF4LLM",
        "description": "Faster PDF conversion with optional image embedding.",
        "badge": "AGPL license",
    },
    Engine.OCR_PLUGIN: {
        "label": "LLM OCR plugin",
        "description": "Vision OCR for embedded or scanned images in PDF/DOCX/PPTX/XLSX.",
        "badge": "LLM cost per image",
    },
}


@dataclass(frozen=True)
class Settings:
    docintel_endpoint: str | None
    azure_api_key: str | None
    llm_base_url: str | None
    llm_api_key: str | None
    llm_model: str | None
    default_engine: Engine

    @classmethod
    def from_env(cls) -> Settings:
        default = os.environ.get("MARKITDOWN_DEFAULT_ENGINE", "builtin")
        try:
            default_engine = Engine(default)
        except ValueError:
            default_engine = Engine.BUILTIN

        return cls(
            docintel_endpoint=_strip_or_none(os.environ.get("MARKITDOWN_DOCINTEL_ENDPOINT")),
            azure_api_key=_strip_or_none(os.environ.get("AZURE_API_KEY")),
            llm_base_url=_strip_or_none(os.environ.get("MARKITDOWN_LLM_BASE_URL")),
            llm_api_key=os.environ.get("MARKITDOWN_LLM_API_KEY", ""),
            llm_model=_strip_or_none(os.environ.get("MARKITDOWN_LLM_MODEL")),
            default_engine=default_engine,
        )

    def llm_client(self) -> Any:
        from openai import OpenAI

        if not self.llm_base_url or not self.llm_model:
            raise RuntimeError("LLM not configured")

        return OpenAI(
            base_url=self.llm_base_url,
            api_key=self.llm_api_key or "not-needed",
        )


def _strip_or_none(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None


def _pymupdf4llm_available() -> bool:
    try:
        import pymupdf4llm  # noqa: F401

        return True
    except ImportError:
        return False


def engine_availability(settings: Settings) -> dict[Engine, tuple[bool, str | None]]:
    out: dict[Engine, tuple[bool, str | None]] = {
        Engine.BUILTIN: (True, None),
    }

    if settings.docintel_endpoint:
        out[Engine.AZURE_DOC_INTEL] = (True, None)
    else:
        out[Engine.AZURE_DOC_INTEL] = (
            False,
            "Set MARKITDOWN_DOCINTEL_ENDPOINT",
        )

    if _pymupdf4llm_available():
        out[Engine.PYMUPDF4LLM] = (True, None)
    else:
        out[Engine.PYMUPDF4LLM] = (False, "Install pymupdf4llm")

    if settings.llm_base_url and settings.llm_model:
        out[Engine.OCR_PLUGIN] = (True, None)
    else:
        out[Engine.OCR_PLUGIN] = (
            False,
            "Set MARKITDOWN_LLM_BASE_URL and MARKITDOWN_LLM_MODEL",
        )

    return out


@lru_cache
def get_settings() -> Settings:
    return Settings.from_env()
