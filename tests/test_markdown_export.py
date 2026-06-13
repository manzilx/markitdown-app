"""Tests for Markdown export (reuses the docx geometry engine)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from markitdown_api.export.markdown import MarkdownExportError, build_markdown
from markitdown_api.main import app


def _block(text, x, y, w, h, redacted=False):
    return {"text": text, "bbox_normalized": [x, y, w, h], "is_redacted": redacted}


def test_plain_mode_uses_title_and_page_headings():
    pages = [
        {"page_number": 1, "ocr_text": "First page text", "blocks": []},
        {"page_number": 2, "ocr_text": "Second page text", "blocks": []},
    ]
    md = build_markdown(pages, title="My Doc")
    assert md.startswith("# My Doc")
    assert "## Page 1" in md
    assert "## Page 2" in md
    assert "First page text" in md


def test_requires_non_empty_pages():
    with pytest.raises(MarkdownExportError):
        build_markdown([])


def test_headings_and_paragraphs_from_geometry():
    page = {
        "page_number": 1,
        "ocr_text": "x",
        "blocks": [
            _block("DOCUMENT TITLE", 0.30, 0.88, 0.40, 0.030),
            _block("Body line alpha here goes", 0.10, 0.80, 0.55, 0.012),
            _block("Body line bravo here goes", 0.10, 0.78, 0.55, 0.012),
            _block("Body line charlie here goes", 0.10, 0.76, 0.55, 0.012),
        ],
    }
    md = build_markdown([page])
    assert "# DOCUMENT TITLE" in md
    # Adjacent body lines flow into one paragraph, not a heading.
    assert "Body line alpha here goes Body line bravo here goes" in md


def test_bullet_and_numbered_lists():
    page = {
        "page_number": 1,
        "ocr_text": "x",
        "blocks": [
            _block("• First point", 0.10, 0.85, 0.40, 0.014),
            _block("• Second point", 0.10, 0.825, 0.40, 0.014),
            _block("1. Step one here", 0.10, 0.78, 0.40, 0.014),
            _block("2. Step two here", 0.10, 0.755, 0.40, 0.014),
        ],
    }
    md = build_markdown([page])
    assert "- First point" in md
    assert "- Second point" in md
    assert "1. Step one here" in md  # source ordinal preserved
    assert "2. Step two here" in md


def test_side_by_side_rows_become_gfm_table_with_numeric_right_align():
    page = {
        "page_number": 1,
        "ocr_text": "x",
        "blocks": [
            _block("Consulting services", 0.08, 0.80, 0.30, 0.014),
            _block("1 250,00", 0.66, 0.80, 0.14, 0.014),
            _block("Travel expenses", 0.08, 0.775, 0.25, 0.014),
            _block("980,50", 0.70, 0.775, 0.10, 0.014),
            _block("Office supplies", 0.08, 0.75, 0.22, 0.014),
            _block("420,00", 0.71, 0.75, 0.09, 0.014),
        ],
    }
    md = build_markdown([page])
    assert "| Consulting services | 1 250,00 |" in md
    # Separator row present, with the numeric column right-aligned.
    assert "| --- | ---: |" in md
    assert "| Travel expenses | 980,50 |" in md


def test_page_break_rule_between_pages():
    pages = [
        {"page_number": 1, "ocr_text": "x", "blocks": [_block("Page one body text here", 0.1, 0.8, 0.6, 0.014)]},
        {"page_number": 2, "ocr_text": "x", "blocks": [_block("Page two body text here", 0.1, 0.8, 0.6, 0.014)]},
    ]
    md = build_markdown(pages)
    assert "\n---\n" in md


def test_endpoint_returns_markdown():
    client = TestClient(app)
    resp = client.post(
        "/v1/export/markdown",
        data={"pages_json": '[{"page_number": 1, "ocr_text": "Hello markdown", "blocks": []}]', "title": "T"},
    )
    assert resp.status_code == 200
    assert "text/markdown" in resp.headers["content-type"]
    assert "Hello markdown" in resp.text


def test_endpoint_rejects_empty():
    client = TestClient(app)
    resp = client.post("/v1/export/markdown", data={"pages_json": "[]"})
    assert resp.status_code == 422
