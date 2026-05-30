"""Tests for searchable PDF export."""

from __future__ import annotations

import io

import pymupdf
import pytest
from fastapi.testclient import TestClient

from markitdown_api.export.searchable_pdf import build_searchable_pdf
from markitdown_api.main import app


def _blank_pdf_bytes() -> bytes:
    doc = pymupdf.open()
    page = doc.new_page(width=400, height=500)
    page.insert_text((72, 72), "Visible sample text", fontsize=14)
    buf = io.BytesIO()
    doc.save(buf)
    doc.close()
    return buf.getvalue()


def test_build_searchable_pdf_adds_hidden_text():
    pdf_bytes = _blank_pdf_bytes()
    pages = [
        {
            "page_number": 1,
            "ocr_text": "Hidden searchable layer",
            "edited_text": None,
            "blocks": [],
        }
    ]
    out = build_searchable_pdf(pdf_bytes, pages)
    doc = pymupdf.open(stream=out, filetype="pdf")
    assert doc.page_count == 1
    text = doc[0].get_text()
    assert "Hidden searchable layer" in text
    doc.close()


def test_export_searchable_pdf_endpoint():
    client = TestClient(app)
    pdf_bytes = _blank_pdf_bytes()
    pages_json = '[{"page_number": 1, "ocr_text": "Endpoint test", "blocks": []}]'
    resp = client.post(
        "/v1/export/searchable-pdf",
        files={"file": ("sample.pdf", pdf_bytes, "application/pdf")},
        data={"pages_json": pages_json},
    )
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/pdf"
    doc = pymupdf.open(stream=resp.content, filetype="pdf")
    assert "Endpoint test" in doc[0].get_text()
    doc.close()


def test_export_requires_pages():
    client = TestClient(app)
    pdf_bytes = _blank_pdf_bytes()
    resp = client.post(
        "/v1/export/searchable-pdf",
        files={"file": ("sample.pdf", pdf_bytes, "application/pdf")},
        data={"pages_json": "[]"},
    )
    assert resp.status_code == 422


def test_export_accepts_multipart_part_over_1mb():
    client = TestClient(app)
    large_pdf = _blank_pdf_bytes() + (b"0" * (1024 * 1024 + 1))
    pages_json = '[{"page_number": 1, "ocr_text": "Large upload test", "blocks": []}]'
    resp = client.post(
        "/v1/export/searchable-pdf",
        files={"file": ("large.pdf", large_pdf, "application/pdf")},
        data={"pages_json": pages_json},
    )
    assert resp.status_code == 200, resp.text
    doc = pymupdf.open(stream=resp.content, filetype="pdf")
    assert "Large upload test" in doc[0].get_text()
    doc.close()
