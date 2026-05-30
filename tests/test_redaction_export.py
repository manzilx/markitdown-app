"""Tests for redaction in searchable PDF export."""

from __future__ import annotations

import io

import pymupdf

from markitdown_api.export.searchable_pdf import build_searchable_pdf


def _blank_pdf_bytes() -> bytes:
    doc = pymupdf.open()
    doc.new_page(width=400, height=500)
    buf = io.BytesIO()
    doc.save(buf)
    doc.close()
    return buf.getvalue()


def _redacted_pages() -> list[dict]:
    return [
        {
            "page_number": 1,
            "ocr_text": "SECRET CODE\nPUBLIC INFO",
            "edited_text": None,
            # Client sends redaction-aware export text (secret removed).
            "export_text": "PUBLIC INFO",
            "blocks": [
                {
                    "text": "SECRET CODE",
                    "confidence": 0.95,
                    "bbox_normalized": [0.1, 0.8, 0.5, 0.06],
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


def test_redacted_text_excluded_from_searchable_pdf():
    out = build_searchable_pdf(_blank_pdf_bytes(), _redacted_pages())
    doc = pymupdf.open(stream=out, filetype="pdf")
    text = doc[0].get_text()
    assert "PUBLIC INFO" in text
    assert "SECRET" not in text
    doc.close()


def test_redaction_draws_black_box():
    out = build_searchable_pdf(_blank_pdf_bytes(), _redacted_pages())
    doc = pymupdf.open(stream=out, filetype="pdf")
    drawings = doc[0].get_drawings()
    # The redacted region should produce at least one filled drawing.
    assert any(d.get("fill") is not None for d in drawings)
    doc.close()
