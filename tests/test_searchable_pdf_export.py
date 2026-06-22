"""Tests for searchable PDF export."""

from __future__ import annotations

import io

import pymupdf
import pytest
from fastapi.testclient import TestClient

from markitdown_api.export.searchable_pdf import SearchablePDFError, build_searchable_pdf
from markitdown_api.main import app


def _blank_pdf_bytes() -> bytes:
    doc = pymupdf.open()
    page = doc.new_page(width=400, height=500)
    page.insert_text((72, 72), "Visible sample text", fontsize=14)
    buf = io.BytesIO()
    doc.save(buf)
    doc.close()
    return buf.getvalue()


def _blank_pdf_with_pages(count: int) -> bytes:
    doc = pymupdf.open()
    for index in range(count):
        page = doc.new_page(width=400, height=500)
        page.insert_text((72, 72), f"Visible page {index + 1}", fontsize=14)
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


def test_build_searchable_pdf_adds_hidden_text_to_multiple_pages():
    pdf_bytes = _blank_pdf_with_pages(3)
    pages = [
        {"page_number": 1, "ocr_text": "Hidden page one", "blocks": []},
        {"page_number": 2, "ocr_text": "Hidden page two", "blocks": []},
        {"page_number": 3, "ocr_text": "Hidden page three", "blocks": []},
    ]
    out = build_searchable_pdf(pdf_bytes, pages)
    doc = pymupdf.open(stream=out, filetype="pdf")
    assert doc.page_count == 3
    assert "Hidden page one" in doc[0].get_text()
    assert "Hidden page two" in doc[1].get_text()
    assert "Hidden page three" in doc[2].get_text()
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


def test_export_searchable_pdf_endpoint_multiple_pages():
    client = TestClient(app)
    pdf_bytes = _blank_pdf_with_pages(2)
    pages_json = (
        "["
        '{"page_number": 1, "ocr_text": "Endpoint page one", "blocks": []},'
        '{"page_number": 2, "ocr_text": "Endpoint page two", "blocks": []}'
        "]"
    )
    resp = client.post(
        "/v1/export/searchable-pdf",
        files={"file": ("sample.pdf", pdf_bytes, "application/pdf")},
        data={"pages_json": pages_json},
    )
    assert resp.status_code == 200, resp.text
    doc = pymupdf.open(stream=resp.content, filetype="pdf")
    assert doc.page_count == 2
    assert "Endpoint page one" in doc[0].get_text()
    assert "Endpoint page two" in doc[1].get_text()
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


def test_build_searchable_pdf_rejects_bad_page_number():
    with pytest.raises(SearchablePDFError, match="page_number"):
        build_searchable_pdf(
            _blank_pdf_bytes(),
            [{"page_number": "not-a-number", "ocr_text": "bad", "blocks": []}],
        )


def test_build_searchable_pdf_ignores_bad_bbox():
    out = build_searchable_pdf(
        _blank_pdf_bytes(),
        [
            {
                "page_number": 1,
                "ocr_text": "Fallback layer",
                "blocks": [
                    {
                        "text": "Fallback layer",
                        "bbox_normalized": ["bad", 0.1, 0.2, 0.3],
                    }
                ],
            }
        ],
    )
    doc = pymupdf.open(stream=out, filetype="pdf")
    assert "Fallback layer" in doc[0].get_text()
    doc.close()


def test_export_searchable_pdf_rejects_malformed_pages_json():
    client = TestClient(app)
    resp = client.post(
        "/v1/export/searchable-pdf",
        files={"file": ("sample.pdf", _blank_pdf_bytes(), "application/pdf")},
        data={"pages_json": '[{"page_number": "nope", "ocr_text": "bad"}]'},
    )
    assert resp.status_code == 422
    assert "page_number" in resp.json()["detail"]


def test_export_searchable_pdf_sanitizes_download_filename():
    client = TestClient(app)
    pages_json = '[{"page_number": 1, "ocr_text": "Header test", "blocks": []}]'
    resp = client.post(
        "/v1/export/searchable-pdf",
        files={"file": ('bad"\r\nx.pdf', _blank_pdf_bytes(), "application/pdf")},
        data={"pages_json": pages_json},
    )
    assert resp.status_code == 200
    disposition = resp.headers["content-disposition"]
    assert "\r" not in disposition
    assert "\n" not in disposition
    assert "filename*=" in disposition
