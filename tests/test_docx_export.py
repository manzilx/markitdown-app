"""Tests for DOCX export."""

from __future__ import annotations

import io
import zipfile

import pytest
from docx import Document
from fastapi.testclient import TestClient

from markitdown_api.export.docx import DOCXExportError, build_docx
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


def test_build_docx_rejects_bad_page_number():
    with pytest.raises(DOCXExportError, match="page_number"):
        build_docx([{"page_number": "bad", "ocr_text": "Nope", "blocks": []}])


def test_export_docx_rejects_malformed_pages_json():
    client = TestClient(app)
    resp = client.post(
        "/v1/export/docx",
        data={"pages_json": '[{"page_number": "bad", "ocr_text": "Nope"}]'},
    )
    assert resp.status_code == 422
    assert "page_number" in resp.json()["detail"]


def test_export_docx_sanitizes_download_filename():
    client = TestClient(app)
    pages_json = '[{"page_number": 1, "ocr_text": "Header test", "blocks": []}]'
    resp = client.post(
        "/v1/export/docx",
        data={"pages_json": pages_json, "title": 'bad"\r\nname'},
    )
    assert resp.status_code == 200
    disposition = resp.headers["content-disposition"]
    assert "\r" not in disposition
    assert "\n" not in disposition
    assert "filename*=" in disposition


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


# ---- Table reconstruction ----

def _table_page():
    """A registry-style page: heading, then 3 label/value rows, then a footer line."""
    rows = []
    labels = [("Company", "ACME Corp"), ("Capital", "81 941 145,00 Euros"), ("Registered", "16/05/1997")]
    y = 0.80
    for label, value in labels:
        rows.append(_block(label, 0.08, y, 0.18, 0.014))
        rows.append(_block(value, 0.40, y, 0.35, 0.014))
        y -= 0.025
    return {
        "page_number": 1,
        "ocr_text": "REGISTRY EXTRACT\n" + "\n".join(f"{l}\n{v}" for l, v in labels) + "\nEnd of extract",
        "blocks": [
            _block("REGISTRY EXTRACT", 0.30, 0.90, 0.40, 0.028),
            *rows,
            _block("End of extract", 0.08, 0.60, 0.30, 0.014),
        ],
    }


def test_side_by_side_rows_become_a_real_table():
    out = build_docx([_table_page()])
    doc = Document(io.BytesIO(out))

    assert len(doc.tables) == 1
    table = doc.tables[0]
    assert len(table.rows) == 3
    assert len(table.columns) == 2
    assert "Company" in table.cell(0, 0).text
    assert "ACME Corp" in table.cell(0, 1).text
    assert "Registered" in table.cell(2, 0).text
    assert "16/05/1997" in table.cell(2, 1).text

    # Heading and footer stay as normal paragraphs outside the table.
    para_text = "\n".join(p.text for p in doc.paragraphs)
    assert "REGISTRY EXTRACT" in para_text
    assert "End of extract" in para_text


def test_plain_paragraph_pages_produce_no_tables():
    out = build_docx([_layout_page()])
    doc = Document(io.BytesIO(out))
    assert len(doc.tables) == 0


def test_body_font_sizes_are_quantized_to_one_class():
    # Slightly jittery line heights (±8%) must export at ONE consistent size.
    page = {
        "page_number": 1,
        "ocr_text": "a\nb\nc",
        "blocks": [
            _block("Line with height jitter one", 0.10, 0.80, 0.7, 0.0140),
            _block("Line with height jitter two", 0.10, 0.75, 0.7, 0.0150),
            _block("Line with height jitter three", 0.10, 0.70, 0.7, 0.0146),
        ],
    }
    out = build_docx([page])
    doc = Document(io.BytesIO(out))
    sizes = {r.font.size for p in doc.paragraphs for r in p.runs if r.font.size}
    assert len(sizes) == 1


def test_right_aligned_numeric_columns_form_a_table():
    # Invoice-style: descriptions left-aligned, amounts RIGHT-aligned (left edges
    # scatter with number width; right edges line up at 0.80).
    page = {
        "page_number": 1,
        "ocr_text": "x",
        "blocks": [
            _block("Consulting services", 0.08, 0.80, 0.30, 0.014),
            _block("1 250,00", 0.66, 0.80, 0.14, 0.014),       # right = 0.80
            _block("Travel expenses", 0.08, 0.775, 0.25, 0.014),
            _block("980,50", 0.70, 0.775, 0.10, 0.014),        # right = 0.80
            _block("Total", 0.08, 0.75, 0.10, 0.014),
            _block("2 230,50", 0.655, 0.75, 0.145, 0.014),     # right = 0.80
        ],
    }
    out = build_docx([page])
    doc = Document(io.BytesIO(out))
    assert len(doc.tables) == 1
    table = doc.tables[0]
    assert len(table.rows) == 3
    assert len(table.columns) == 2
    assert "1 250,00" in table.cell(0, 1).text
    assert "980,50" in table.cell(1, 1).text
    assert "2 230,50" in table.cell(2, 1).text


def test_wrapped_cell_value_merges_into_previous_row():
    # Row 1's value wraps onto a second line sitting at the value column.
    page = {
        "page_number": 1,
        "ocr_text": "x",
        "blocks": [
            _block("Address", 0.08, 0.800, 0.15, 0.014),
            _block("167 Quai la Bataille", 0.40, 0.800, 0.35, 0.014),
            _block("92130 Issy-les-Moulineaux", 0.40, 0.780, 0.33, 0.014),  # continuation
            _block("Manager", 0.08, 0.755, 0.15, 0.014),
            _block("POT Nicolas", 0.40, 0.755, 0.25, 0.014),
            # Footer at the LEFT column position must NOT be absorbed as continuation.
            _block("End of section marker text", 0.08, 0.700, 0.40, 0.014),
        ],
    }
    out = build_docx([page])
    doc = Document(io.BytesIO(out))
    assert len(doc.tables) == 1
    table = doc.tables[0]
    assert len(table.rows) == 2, "wrapped line must merge, not create a third row"
    assert "167 Quai la Bataille" in table.cell(0, 1).text
    assert "92130 Issy-les-Moulineaux" in table.cell(0, 1).text
    assert "POT Nicolas" in table.cell(1, 1).text
    para_text = "\n".join(p.text for p in doc.paragraphs)
    assert "End of section marker text" in para_text, "left-edge footer must stay a paragraph"
