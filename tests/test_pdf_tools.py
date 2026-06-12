"""Tests for PDF combine/split tools."""

from __future__ import annotations

import io

import pymupdf
import pytest
from fastapi.testclient import TestClient

from markitdown_api.main import app
from markitdown_api.pdf_tools import PDFToolsError, combine_pdfs, extract_page_range


def _pdf_with_pages(count: int, label: str) -> bytes:
    doc = pymupdf.open()
    for index in range(count):
        page = doc.new_page(width=400, height=500)
        page.insert_text((72, 72), f"{label} page {index + 1}", fontsize=14)
    buf = io.BytesIO()
    doc.save(buf)
    doc.close()
    return buf.getvalue()


def test_combine_pdfs():
    a = _pdf_with_pages(2, "A")
    b = _pdf_with_pages(3, "B")
    out = combine_pdfs([a, b])
    doc = pymupdf.open(stream=out, filetype="pdf")
    assert doc.page_count == 5
    doc.close()


def test_extract_page_range():
    pdf = _pdf_with_pages(5, "Doc")
    out = extract_page_range(pdf, 2, 4)
    doc = pymupdf.open(stream=out, filetype="pdf")
    assert doc.page_count == 3
    assert "Doc page 2" in doc[0].get_text()
    doc.close()


def test_combine_endpoint():
    client = TestClient(app)
    a = _pdf_with_pages(1, "One")
    b = _pdf_with_pages(1, "Two")
    resp = client.post(
        "/v1/pdf/combine",
        files=[
            ("files", ("one.pdf", a, "application/pdf")),
            ("files", ("two.pdf", b, "application/pdf")),
        ],
    )
    assert resp.status_code == 200
    doc = pymupdf.open(stream=resp.content, filetype="pdf")
    assert doc.page_count == 2
    doc.close()


def test_split_endpoint():
    client = TestClient(app)
    pdf = _pdf_with_pages(4, "Split")
    resp = client.post(
        "/v1/pdf/split",
        files={"file": ("doc.pdf", pdf, "application/pdf")},
        data={"start_page": "2", "end_page": "3"},
    )
    assert resp.status_code == 200
    doc = pymupdf.open(stream=resp.content, filetype="pdf")
    assert doc.page_count == 2
    doc.close()


def test_combine_rejects_invalid_pdf():
    with pytest.raises(PDFToolsError, match="valid PDF"):
        combine_pdfs([_pdf_with_pages(1, "Good"), b"not a pdf"])


def test_combine_endpoint_rejects_invalid_pdf():
    client = TestClient(app)
    good = _pdf_with_pages(1, "Good")
    resp = client.post(
        "/v1/pdf/combine",
        files=[
            ("files", ("good.pdf", good, "application/pdf")),
            ("files", ("bad.pdf", b"not a pdf", "application/pdf")),
        ],
    )
    assert resp.status_code == 400
    assert "valid PDF" in resp.json()["detail"]


def test_split_endpoint_rejects_invalid_pdf():
    client = TestClient(app)
    resp = client.post(
        "/v1/pdf/split",
        files={"file": ("bad.pdf", b"not a pdf", "application/pdf")},
        data={"start_page": "1", "end_page": "1"},
    )
    assert resp.status_code == 400
    assert "valid PDF" in resp.json()["detail"]
