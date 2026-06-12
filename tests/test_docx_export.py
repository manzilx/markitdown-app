"""Tests for DOCX export."""

from __future__ import annotations

import io
import zipfile

import pytest
from docx import Document
from fastapi.testclient import TestClient

from markitdown_api.export.docx import build_docx
from markitdown_api.main import app


def test_build_docx_uses_edited_text():
    pages = [
        {
            "page_number": 1,
            "ocr_text": "Original OCR",
            "edited_text": "Corrected text",
            "blocks": [],
        },
        {
            "page_number": 2,
            "ocr_text": "Page two",
            "edited_text": None,
            "blocks": [],
        },
    ]
    out = build_docx(pages, title="Sample Doc")
    doc = Document(io.BytesIO(out))
    full_text = "\n".join(p.text for p in doc.paragraphs)
    assert "Corrected text" in full_text
    assert "Original OCR" not in full_text
    assert "Page two" in full_text
    assert "Page 1" in full_text
    assert "Page 2" in full_text


def test_export_docx_endpoint():
    client = TestClient(app)
    pages_json = (
        '[{"page_number": 1, "ocr_text": "Endpoint DOCX test", "blocks": []}]'
    )
    resp = client.post(
        "/v1/export/docx",
        data={"pages_json": pages_json, "title": "Endpoint Test"},
    )
    assert resp.status_code == 200
    assert "wordprocessingml" in resp.headers["content-type"]
    assert zipfile.is_zipfile(io.BytesIO(resp.content))
    doc = Document(io.BytesIO(resp.content))
    assert any("Endpoint DOCX test" in p.text for p in doc.paragraphs)


def test_export_docx_requires_pages():
    client = TestClient(app)
    resp = client.post("/v1/export/docx", data={"pages_json": "[]"})
    assert resp.status_code == 422


# ---- Layout mode (geometry-aware formatting) ----

def _block(text, x, y, w, h, redacted=False):
    return {"text": text, "bbox_normalized": [x, y, w, h], "is_redacted": redacted}


def _layout_page(number=1):
    """A page like a letter: big centered title, body paragraph, indented line."""
    return {
        "page_number": number,
        "ocr_text": "ACME REPORT\nBody line one continues here\nBody line two of paragraph\nIndented note",
        "blocks": [
            # Title: tall (2.2% of page height ~ 15pt vs body ~9pt), centered.
            _block("ACME REPORT", 0.35, 0.90, 0.30, 0.030),
            # Body paragraph: two adjacent lines, normal height, left column.
            _block("Body line one continues here", 0.10, 0.80, 0.80, 0.014),
            _block("Body line two of paragraph", 0.10, 0.78, 0.78, 0.014),
            # Indented short line after a vertical gap.
            _block("Indented note", 0.25, 0.70, 0.30, 0.014),
        ],
    }


def test_layout_mode_formats_from_geometry():
    out = build_docx([_layout_page()], title="Should Not Appear")
    doc = Document(io.BytesIO(out))
    texts = [p.text for p in doc.paragraphs if p.text.strip()]

    # No injected title or page headings in layout mode.
    assert all("Should Not Appear" not in t for t in texts)
    assert all("Page 1" not in t for t in texts)

    title_para = next(p for p in doc.paragraphs if "ACME REPORT" in p.text)
    body_para = next(p for p in doc.paragraphs if "Body line one" in p.text)

    # Title is bolded, larger than body, and centered.
    assert title_para.runs[0].font.bold
    assert title_para.runs[0].font.size > body_para.runs[0].font.size
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    assert title_para.alignment == WD_ALIGN_PARAGRAPH.CENTER

    # Adjacent body lines merged into one flowing paragraph.
    assert "Body line one continues here Body line two of paragraph" in body_para.text

    # Indented line keeps its indent.
    indent_para = next(p for p in doc.paragraphs if "Indented note" in p.text)
    assert indent_para.paragraph_format.left_indent is not None


def test_layout_mode_page_breaks_without_headings():
    out = build_docx([_layout_page(1), _layout_page(2)])
    doc = Document(io.BytesIO(out))
    xml = doc.element.xml
    assert xml.count('w:type="page"') >= 1 or 'w:br' in xml
    assert all("Page 1" not in p.text and "Page 2" not in p.text for p in doc.paragraphs)


def test_layout_mode_falls_back_when_page_text_edited():
    page = _layout_page()
    page["edited_text"] = "Completely rewritten by the user"
    out = build_docx([page], title="Edited Doc")
    doc = Document(io.BytesIO(out))
    full_text = "\n".join(p.text for p in doc.paragraphs)
    # The user's edit wins; geometry blocks are not exported.
    assert "Completely rewritten by the user" in full_text
    assert "Body line one" not in full_text


def test_layout_mode_skips_redacted_blocks():
    page = _layout_page()
    page["blocks"].append(_block("SECRET", 0.1, 0.60, 0.3, 0.014, redacted=True))
    out = build_docx([page])
    doc = Document(io.BytesIO(out))
    assert all("SECRET" not in p.text for p in doc.paragraphs)
