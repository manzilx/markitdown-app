"""Export API routes."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import Response

from markitdown_api.export.docx import DOCXExportError, build_docx
from markitdown_api.export.markdown import MarkdownExportError, build_markdown
from markitdown_api.export.searchable_pdf import (
    SearchablePDFError,
    build_searchable_pdf,
    build_searchable_pdf_from_image,
)

router = APIRouter(prefix="/v1/export", tags=["export"])

MAX_EXPORT_BYTES = 100 * 1024 * 1024

_IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".heic"}


@router.post("/searchable-pdf")
async def export_searchable_pdf(
    file: UploadFile = File(...),
    pages_json: str = Form(...),
) -> Response:
    filename = file.filename or "document.pdf"
    ext = Path(filename).suffix.lower()

    try:
        pages = json.loads(pages_json)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=422, detail="Invalid pages_json") from exc

    if not isinstance(pages, list) or not pages:
        raise HTTPException(status_code=422, detail="pages_json must be a non-empty array")

    data = await file.read()
    if len(data) > MAX_EXPORT_BYTES:
        raise HTTPException(status_code=413, detail="File exceeds 100 MB export limit")

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
        raise HTTPException(status_code=500, detail=f"Export failed: {exc}") from exc

    stem = Path(filename).stem
    out_name = f"{stem}_searchable.pdf"
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{out_name}"'},
    )


@router.post("/docx")
async def export_docx(
    pages_json: str = Form(...),
    title: str = Form(""),
) -> Response:
    try:
        pages = json.loads(pages_json)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=422, detail="Invalid pages_json") from exc

    if not isinstance(pages, list) or not pages:
        raise HTTPException(status_code=422, detail="pages_json must be a non-empty array")

    doc_title = title.strip() or "OCR Export"

    try:
        docx_bytes = build_docx(pages, title=doc_title)
    except DOCXExportError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Export failed: {exc}") from exc

    safe_title = "".join(c if c.isalnum() or c in " -_" else "_" for c in doc_title)[:80]
    out_name = f"{safe_title or 'export'}.docx"
    return Response(
        content=docx_bytes,
        media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        headers={"Content-Disposition": f'attachment; filename="{out_name}"'},
    )


@router.post("/markdown")
async def export_markdown(
    pages_json: str = Form(...),
    title: str = Form(""),
) -> Response:
    try:
        pages = json.loads(pages_json)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=422, detail="Invalid pages_json") from exc

    if not isinstance(pages, list) or not pages:
        raise HTTPException(status_code=422, detail="pages_json must be a non-empty array")

    doc_title = title.strip() or "OCR Export"

    try:
        markdown_text = build_markdown(pages, title=doc_title)
    except MarkdownExportError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Export failed: {exc}") from exc

    safe_title = "".join(c if c.isalnum() or c in " -_" else "_" for c in doc_title)[:80]
    out_name = f"{safe_title or 'export'}.md"
    return Response(
        content=markdown_text.encode("utf-8"),
        media_type="text/markdown; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{out_name}"'},
    )
