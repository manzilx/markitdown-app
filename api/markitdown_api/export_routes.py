"""Export API routes."""

from __future__ import annotations

import json
import logging
from pathlib import Path

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import Response

from markitdown_api.export.docx import DOCXExportError, build_docx
from markitdown_api.export.markdown import MarkdownExportError, build_markdown
from markitdown_api.export.payload import (
    MAX_EXPORT_JSON_BYTES,
    ExportPayloadError,
    normalize_export_pages,
)
from markitdown_api.export.searchable_pdf import (
    SearchablePDFError,
    build_searchable_pdf,
    build_searchable_pdf_from_image,
)
from markitdown_api.http_utils import (
    UploadTooLargeError,
    attachment_headers,
    read_upload_limited,
)

router = APIRouter(prefix="/v1/export", tags=["export"])
logger = logging.getLogger(__name__)

MAX_EXPORT_BYTES = 100 * 1024 * 1024

_IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".heic"}


def _parse_pages_json(pages_json: str) -> list[dict]:
    if len(pages_json.encode("utf-8")) > MAX_EXPORT_JSON_BYTES:
        raise HTTPException(status_code=413, detail="pages_json exceeds 10 MB limit")

    try:
        raw_pages = json.loads(pages_json)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=422, detail="Invalid pages_json") from exc

    try:
        return normalize_export_pages(raw_pages)
    except ExportPayloadError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post("/searchable-pdf")
async def export_searchable_pdf(
    file: UploadFile = File(...),
    pages_json: str = Form(...),
) -> Response:
    filename = file.filename or "document.pdf"
    ext = Path(filename).suffix.lower()
    pages = _parse_pages_json(pages_json)

    try:
        data = await read_upload_limited(file, MAX_EXPORT_BYTES)
    except UploadTooLargeError as exc:
        raise HTTPException(status_code=413, detail="File exceeds 100 MB export limit") from exc

    try:
        if ext == ".pdf":
            pdf_bytes = build_searchable_pdf(data, pages)
        elif ext in _IMAGE_EXTENSIONS:
            if len(pages) != 1:
                raise HTTPException(
                    status_code=422,
                    detail="Image export expects exactly one page in pages_json",
                )
            pdf_bytes = build_searchable_pdf_from_image(data, pages[0])
        else:
            raise HTTPException(
                status_code=415,
                detail="Searchable PDF export supports PDF and image files only",
            )
    except SearchablePDFError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("Searchable PDF export failed for %s", filename)
        raise HTTPException(status_code=500, detail="Export failed") from exc

    stem = Path(filename).stem
    out_name = f"{stem}_searchable.pdf"
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers=attachment_headers(out_name),
    )


@router.post("/docx")
async def export_docx(
    pages_json: str = Form(...),
    title: str = Form(""),
) -> Response:
    pages = _parse_pages_json(pages_json)
    doc_title = title.strip() or "OCR Export"

    try:
        docx_bytes = build_docx(pages, title=doc_title)
    except DOCXExportError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("DOCX export failed")
        raise HTTPException(status_code=500, detail="Export failed") from exc

    out_name = f"{doc_title or 'export'}.docx"
    return Response(
        content=docx_bytes,
        media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        headers=attachment_headers(out_name),
    )


@router.post("/markdown")
async def export_markdown(
    pages_json: str = Form(...),
    title: str = Form(""),
) -> Response:
    pages = _parse_pages_json(pages_json)
    doc_title = title.strip() or "OCR Export"

    try:
        markdown_text = build_markdown(pages, title=doc_title)
    except MarkdownExportError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("Markdown export failed")
        raise HTTPException(status_code=500, detail="Export failed") from exc

    out_name = f"{doc_title or 'export'}.md"
    return Response(
        content=markdown_text.encode("utf-8"),
        media_type="text/markdown; charset=utf-8",
        headers=attachment_headers(out_name),
    )
