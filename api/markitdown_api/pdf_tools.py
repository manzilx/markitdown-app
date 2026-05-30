"""PDF combine and split utilities using PyMuPDF."""

from __future__ import annotations

import io

import pymupdf


class PDFToolsError(Exception):
    pass


def combine_pdfs(parts: list[bytes]) -> bytes:
    if not parts:
        raise PDFToolsError("No PDF files provided")

    output = pymupdf.open()
    try:
        for part in parts:
            src = pymupdf.open(stream=part, filetype="pdf")
            output.insert_pdf(src)
            src.close()
        if output.page_count == 0:
            raise PDFToolsError("Combined PDF has no pages")
        buf = io.BytesIO()
        output.save(buf, garbage=4, deflate=True)
        return buf.getvalue()
    finally:
        output.close()


def extract_page_range(pdf_bytes: bytes, start_page: int, end_page: int) -> bytes:
    """Extract inclusive 1-based page range."""
    if start_page < 1 or end_page < start_page:
        raise PDFToolsError("Invalid page range")

    src = pymupdf.open(stream=pdf_bytes, filetype="pdf")
    if end_page > src.page_count:
        src.close()
        raise PDFToolsError(f"End page {end_page} exceeds document length ({src.page_count})")

    output = pymupdf.open()
    try:
        output.insert_pdf(src, from_page=start_page - 1, to_page=end_page - 1)
        buf = io.BytesIO()
        output.save(buf, garbage=4, deflate=True)
        return buf.getvalue()
    finally:
        output.close()
        src.close()
