"""MarkItDown conversion with selectable engines."""

from __future__ import annotations

from io import BytesIO
from pathlib import Path

from markitdown import MarkItDown

from markitdown_api.config import (
    Engine,
    IMAGE_EXTENSIONS,
    PAGE_IMAGE_OCR_ENGINES,
    Settings,
    engine_availability,
)


class EngineUnavailableError(Exception):
    def __init__(self, engine: Engine, reason: str) -> None:
        self.engine = engine
        self.reason = reason
        super().__init__(reason)


class UnsupportedFileError(Exception):
    pass


def validate_extension(filename: str) -> str:
    ext = Path(filename).suffix.lower()
    from markitdown_api.config import ALLOWED_EXTENSIONS

    if ext not in ALLOWED_EXTENSIONS:
        raise UnsupportedFileError(f"Unsupported file type: {ext or '(none)'}")
    return ext


def validate_engine_for_file(filename: str, engine: Engine) -> None:
    ext = validate_extension(filename)
    if ext in IMAGE_EXTENSIONS and engine not in PAGE_IMAGE_OCR_ENGINES:
        raise ValueError(
            f"{engine.value} cannot OCR page images. Use Apple Vision in the app, "
            "or choose an OCR-capable sidecar engine."
        )


def build_markitdown(engine: Engine, settings: Settings) -> MarkItDown:
    if engine == Engine.AZURE_DOC_INTEL:
        if not settings.docintel_endpoint:
            raise EngineUnavailableError(engine, "Set MARKITDOWN_DOCINTEL_ENDPOINT")
        return MarkItDown(docintel_endpoint=settings.docintel_endpoint)

    if engine == Engine.OCR_PLUGIN:
        return MarkItDown(
            enable_plugins=True,
            llm_client=settings.llm_client(),
            llm_model=settings.llm_model,
        )

    return MarkItDown(enable_plugins=False)


def ensure_engine_available(engine: Engine, settings: Settings) -> None:
    available, reason = engine_availability(settings)[engine]
    if not available:
        raise EngineUnavailableError(engine, reason or "Engine unavailable")


def convert_upload(
    filename: str,
    data: bytes,
    engine: Engine,
    settings: Settings,
    *,
    embed_images: bool = False,
) -> str:
    if not data:
        raise ValueError("Empty file")

    validate_engine_for_file(filename, engine)
    ensure_engine_available(engine, settings)

    stream = BytesIO(data)
    md = build_markitdown(engine, settings)
    kwargs: dict = {}

    if engine == Engine.PYMUPDF4LLM:
        kwargs["use_pdf4llm"] = True
        if embed_images:
            kwargs["args_pdf4llm"] = {
                "page_chunks": False,
                "write_images": False,
                "embed_images": True,
                "dpi": 150,
            }

    result = md.convert_stream(stream, file_extension=Path(filename).suffix, **kwargs)
    return result.text_content or ""
