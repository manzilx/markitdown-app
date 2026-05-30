"""Build Word documents from OCR page data."""

from __future__ import annotations

import io
from typing import Any

from docx import Document

from markitdown_api.export.searchable_pdf import _page_text


class DOCXExportError(Exception):
    pass


def build_docx(pages: list[dict[str, Any]], title: str = "OCR Export") -> bytes:
    """Create a .docx from OCR pages using edited_text when present."""
    if not pages:
        raise DOCXExportError("No OCR pages provided")

    pages_by_number = sorted(
        (p for p in pages if "page_number" in p),
        key=lambda p: int(p["page_number"]),
    )
    if not pages_by_number:
        raise DOCXExportError("No valid page numbers in OCR data")

    doc = Document()
    doc.add_heading(title, level=0)

    multi_page = len(pages_by_number) > 1
    for page_data in pages_by_number:
        page_number = int(page_data["page_number"])
        text = _page_text(page_data).strip()
        if not text:
            continue

        if multi_page:
            doc.add_heading(f"Page {page_number}", level=1)

        for line in text.splitlines():
            doc.add_paragraph(line)

    out = io.BytesIO()
    doc.save(out)
    return out.getvalue()
