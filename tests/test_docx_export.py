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
