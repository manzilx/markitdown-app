"""PDF manipulation routes."""

from __future__ import annotations

import logging

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import Response

from markitdown_api.export_routes import MAX_EXPORT_BYTES
from markitdown_api.http_utils import (
    UploadTooLargeError,
    attachment_headers,
    read_upload_limited,
)
from markitdown_api.pdf_tools import PDFToolsError, combine_pdfs, extract_page_range

router = APIRouter(prefix="/v1/pdf", tags=["pdf"])
logger = logging.getLogger(__name__)

MAX_COMBINE_FILES = 50
MAX_COMBINE_TOTAL_BYTES = 250 * 1024 * 1024


@router.post("/combine")
async def combine_pdf_files(files: list[UploadFile] = File(...)) -> Response:
    if len(files) < 2:
        raise HTTPException(status_code=422, detail="Provide at least two PDF files")
    if len(files) > MAX_COMBINE_FILES:
        raise HTTPException(status_code=413, detail=f"Cannot combine more than {MAX_COMBINE_FILES} files")

    parts: list[bytes] = []
    total_bytes = 0
    for upload in files:
        try:
            data = await read_upload_limited(upload, MAX_EXPORT_BYTES)
        except UploadTooLargeError as exc:
            raise HTTPException(status_code=413, detail="File exceeds 100 MB limit") from exc
        total_bytes += len(data)
        if total_bytes > MAX_COMBINE_TOTAL_BYTES:
            raise HTTPException(status_code=413, detail="Combined input exceeds 250 MB limit")
        parts.append(data)

    try:
        pdf_bytes = combine_pdfs(parts)
    except PDFToolsError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("PDF combine failed")
        raise HTTPException(status_code=500, detail="Combine failed") from exc

    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers=attachment_headers("combined.pdf"),
    )


@router.post("/split")
async def split_pdf_file(
    file: UploadFile = File(...),
    start_page: int = Form(...),
    end_page: int = Form(...),
) -> Response:
    try:
        data = await read_upload_limited(file, MAX_EXPORT_BYTES)
    except UploadTooLargeError as exc:
        raise HTTPException(status_code=413, detail="File exceeds 100 MB limit") from exc

    try:
        pdf_bytes = extract_page_range(data, start_page, end_page)
    except PDFToolsError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("PDF split failed")
        raise HTTPException(status_code=500, detail="Split failed") from exc

    filename = f"pages_{start_page}-{end_page}.pdf"
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers=attachment_headers(filename),
    )
