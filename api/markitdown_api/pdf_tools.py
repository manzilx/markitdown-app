"""PDF combine and split utilities using PyMuPDF."""

from __future__ import annotations

import io

import pymupdf


class PDFToolsError(Exception):
    pass


def _open_pdf(pdf_bytes: bytes, label: str) -> pymupdf.Document:
    if not pdf_bytes:
        raise PDFToolsError(f"{label} is empty")

    try:
        doc = pymupdf.open(stream=pdf_bytes, filetype="pdf")
    except Exception as exc:
        raise PDFToolsError(f"{label} is not a valid PDF") from exc

    if doc.page_count == 0:
        doc.close()
        raise PDFToolsError(f"{label} has no pages")

    return doc


def combine_pdfs(parts: list[bytes]) -> bytes:
    if not parts:
        raise PDFToolsError("No PDF files provided")

    output = pymupdf.open()
    try:
        for index, part in enumerate(parts, start=1):
            src = _open_pdf(part, f"File {index}")
            try:
                output.insert_pdf(src)
            except Exception as exc:
                raise PDFToolsError(f"Could not combine file {index}") from exc
            finally:
                src.close()

        if output.page_count == 0:
            raise PDFToolsError("Combined PDF has no pages")

        buf = io.BytesIO()
        try:
            output.save(buf, garbage=4, deflate=True)
        except Exception as exc:
            raise PDFToolsError("Could not save combined PDF") from exc
        return buf.getvalue()
    finally:
        output.close()


def extract_page_range(pdf_bytes: bytes, start_page: int, end_page: int) -> bytes:
    """Extract inclusive 1-based page range."""
    if start_page < 1 or end_page < start_page:
        raise PDFToolsError("Invalid page range")

    src = _open_pdf(pdf_bytes, "Source PDF")

    output = pymupdf.open()
    try:
        if end_page > src.page_count:
            raise PDFToolsError(f"End page {end_page} exceeds document length ({src.page_count})")

        try:
            output.insert_pdf(src, from_page=start_page - 1, to_page=end_page - 1)
        except Exception as exc:
            raise PDFToolsError("Could not extract requested pages") from exc

        buf = io.BytesIO()
        try:
            output.save(buf, garbage=4, deflate=True)
        except Exception as exc:
            raise PDFToolsError("Could not save extracted PDF") from exc
        return buf.getvalue()
    finally:
        output.close()
        src.close()
