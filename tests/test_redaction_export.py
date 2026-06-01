"""Tests for redaction in searchable PDF export.

Verifies *true* redaction: content under a redacted region is permanently removed
from the output PDF (not merely covered by an opaque box, which would leave the
original recoverable).
"""

from __future__ import annotations

import io

import pymupdf

from markitdown_api.export.searchable_pdf import build_searchable_pdf


def _pdf_with_text() -> bytes:
    """A page with real text: 'SECRET CODE' near the top, 'PUBLIC INFO' near the bottom."""
    doc = pymupdf.open()
    page = doc.new_page(width=400, height=500)
    page.insert_text((60, 60), "SECRET CODE", fontsize=14)
    page.insert_text((60, 400), "PUBLIC INFO", fontsize=14)
    buf = io.BytesIO()
    doc.save(buf)
    doc.close()
    return buf.getvalue()


def _redacted_pages() -> list[dict]:
    # SECRET block is redacted; its bbox (Vision-normalized, bottom-left origin)
    # maps to the top region where 'SECRET CODE' was drawn.
    return [
        {
            "page_number": 1,
            "ocr_text": "SECRET CODE\nPUBLIC INFO",
            "edited_text": None,
            "export_text": "PUBLIC INFO",
            "blocks": [
                {
                    "text": "SECRET CODE",
                    "confidence": 0.95,
                    "bbox_normalized": [0.1, 0.86, 0.5, 0.06],
                    "is_redacted": True,
                },
                {
                    "text": "PUBLIC INFO",
                    "confidence": 0.95,
                    "bbox_normalized": [0.1, 0.1, 0.5, 0.06],
                    "is_redacted": False,
                },
            ],
        }
    ]


def test_redaction_permanently_removes_underlying_text():
    out = build_searchable_pdf(_pdf_with_text(), _redacted_pages())
    doc = pymupdf.open(stream=out, filetype="pdf")
    text = doc[0].get_text()
    # The redacted text must be GONE from the file, not just visually covered.
    assert "SECRET" not in text
    # Non-redacted content survives.
    assert "PUBLIC INFO" in text
    doc.close()


def test_redaction_leaves_a_filled_box():
    out = build_searchable_pdf(_pdf_with_text(), _redacted_pages())
    doc = pymupdf.open(stream=out, filetype="pdf")
    drawings = doc[0].get_drawings()
    assert any(d.get("fill") is not None for d in drawings)
    doc.close()


def test_no_redaction_keeps_all_text():
    pages = _redacted_pages()
    for b in pages[0]["blocks"]:
        b["is_redacted"] = False
    pages[0]["export_text"] = pages[0]["ocr_text"]
    out = build_searchable_pdf(_pdf_with_text(), pages)
    doc = pymupdf.open(stream=out, filetype="pdf")
    text = doc[0].get_text()
    assert "SECRET CODE" in text
    assert "PUBLIC INFO" in text
    doc.close()
