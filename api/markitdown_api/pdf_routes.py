"""PDF manipulation routes."""

from __future__ import annotations

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import Response

from markitdown_api.export_routes import MAX_EXPORT_BYTES
from markitdown_api.pdf_tools import PDFToolsError, combine_pdfs, extract_page_range

router = APIRouter(prefix="/v1/pdf", tags=["pdf"])


@router.post("/combine")
async def combine_pdf_files(files: list[UploadFile] = File(...)) -> Response:
    if len(files) < 2:
        raise HTTPException(status_code=422, detail="Provide at least two PDF files")

    parts: list[bytes] = []
    for upload in files:
        data = await upload.read()
        if len(data) > MAX_EXPORT_BYTES:
            raise HTTPException(status_code=413, detail="File exceeds 100 MB limit")
        parts.append(data)

    try:
        pdf_bytes = combine_pdfs(parts)
    except PDFToolsError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Combine failed: {exc}") from exc

    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": 'attachment; filename="combined.pdf"'},
    )


@router.post("/split")
async def split_pdf_file(
    file: UploadFile = File(...),
    start_page: int = Form(...),
    end_page: int = Form(...),
) -> Response:
    data = await file.read()
    if len(data) > MAX_EXPORT_BYTES:
        raise HTTPException(status_code=413, detail="File exceeds 100 MB limit")

    try:
        pdf_bytes = extract_page_range(data, start_page, end_page)
    except PDFToolsError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Split failed: {exc}") from exc

    filename = f"pages_{start_page}-{end_page}.pdf"
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
