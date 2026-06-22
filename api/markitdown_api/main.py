"""FastAPI app for MarkItDown document conversion."""

from __future__ import annotations

import logging

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from markitdown_api.config import (
    MAX_UPLOAD_BYTES,
    Engine,
    ENGINE_META,
    PAGE_IMAGE_OCR_ENGINES,
    engine_availability,
    get_settings,
)
from markitdown_api.converter import (
    EngineUnavailableError,
    UnsupportedFileError,
    convert_upload,
    validate_extension,
)
from markitdown_api.export_routes import router as export_router
from markitdown_api.http_utils import UploadTooLargeError, read_upload_limited
from markitdown_api.multipart_limits import apply_multipart_limit_patch
from markitdown_api.pdf_routes import router as pdf_router

apply_multipart_limit_patch()

logger = logging.getLogger(__name__)

app = FastAPI(
    title="MarkItDown API",
    version="0.1.0",
    description="Convert documents to Markdown with selectable engines",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5174",
        "http://127.0.0.1:5174",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(export_router)
app.include_router(pdf_router)


class EngineInfo(BaseModel):
    id: str
    label: str
    description: str
    badge: str
    available: bool
    supports_ocr: bool
    reason: str | None = None


class EnginesResponse(BaseModel):
    engines: list[EngineInfo]
    default_engine: str


class ConvertResponse(BaseModel):
    filename: str
    engine: str
    markdown: str
    title: str


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/v1/engines", response_model=EnginesResponse)
def list_engines() -> EnginesResponse:
    settings = get_settings()
    availability = engine_availability(settings)
    engines = [
        EngineInfo(
            id=engine.value,
            label=ENGINE_META[engine]["label"],
            description=ENGINE_META[engine]["description"],
            badge=ENGINE_META[engine]["badge"],
            available=availability[engine][0],
            supports_ocr=engine in PAGE_IMAGE_OCR_ENGINES,
            reason=availability[engine][1],
        )
        for engine in Engine
    ]
    return EnginesResponse(
        engines=engines,
        default_engine=settings.default_engine.value,
    )


@app.post("/v1/convert", response_model=ConvertResponse)
async def convert_document(
    file: UploadFile = File(...),
    engine: str = Form("builtin"),
    embed_images: bool = Form(False),
) -> ConvertResponse:
    settings = get_settings()

    try:
        selected_engine = Engine(engine)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=f"Unknown engine: {engine}") from exc

    filename = file.filename or "upload"
    try:
        validate_extension(filename)
    except UnsupportedFileError as exc:
        raise HTTPException(status_code=415, detail=str(exc)) from exc

    try:
        data = await read_upload_limited(file, MAX_UPLOAD_BYTES)
    except UploadTooLargeError as exc:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds {MAX_UPLOAD_BYTES // (1024 * 1024)} MB limit",
        ) from exc

    try:
        markdown = convert_upload(
            filename,
            data,
            selected_engine,
            settings,
            embed_images=embed_images,
        )
    except EngineUnavailableError as exc:
        raise HTTPException(status_code=503, detail=exc.reason) from exc
    except UnsupportedFileError as exc:
        raise HTTPException(status_code=415, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("Conversion failed for %s with engine %s", filename, selected_engine.value)
        raise HTTPException(status_code=500, detail="Conversion failed") from exc

    return ConvertResponse(
        filename=filename,
        engine=selected_engine.value,
        markdown=markdown,
        title=filename,
    )
