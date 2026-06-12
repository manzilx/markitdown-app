"""Build Word documents from OCR page data.

Two modes per page:

- **Layout mode** (page has block geometry): reconstruct the original document's
  look from the OCR bounding boxes — font sizes derived from line heights,
  oversized lines bolded as headings, centered/right alignment detected from
  block positions, paragraphs grouped by vertical gaps, indents preserved, and a
  page break between pages. No artificial "Page N" headings.
- **Plain mode** (no usable geometry, or the user edited the page's text as a
  whole so the blocks no longer describe it): the legacy line-per-paragraph dump
  with the document title and per-page headings.
"""

from __future__ import annotations

import io
import statistics
from dataclasses import dataclass
from typing import Any

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.shared import Inches, Pt

from markitdown_api.export.searchable_pdf import _page_text


class DOCXExportError(Exception):
    pass


# US-Letter reference frame for converting normalized geometry to points/inches.
_PAGE_HEIGHT_PT = 792.0
_PAGE_WIDTH_IN = 8.5
# Empirical: a text line's bbox (ascender to descender) is ~1.2x the font size.
_FONT_FACTOR = 0.85


@dataclass
class _Line:
    text: str
    left: float    # normalized, from page left
    right: float
    top: float     # normalized, from page TOP (flipped from Vision's bottom-left)
    height: float

    @property
    def center(self) -> float:
        return (self.left + self.right) / 2

    @property
    def width(self) -> float:
        return self.right - self.left


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

    page_lines = [_layout_lines(p) for p in pages_by_number]
    if not any(page_lines):
        return _build_plain(pages_by_number, title)

    doc = Document()
    _fit_margins(doc, [line for lines in page_lines if lines for line in lines])

    first_content = True
    for page_data, lines in zip(pages_by_number, page_lines):
        text = _page_text(page_data).strip()
        if not text and not lines:
            continue
        if not first_content:
            doc.add_page_break()
        first_content = False

        if lines:
            _render_layout_page(doc, lines)
        else:
            for raw in text.splitlines():
                doc.add_paragraph(raw)

    out = io.BytesIO()
    doc.save(out)
    return out.getvalue()


def _build_plain(pages_by_number: list[dict[str, Any]], title: str) -> bytes:
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


def _layout_lines(page_data: dict[str, Any]) -> list[_Line]:
    """Geometry lines in reading order, or [] when layout mode can't be trusted."""
    blocks = page_data.get("blocks") or []
    lines: list[_Line] = []
    for block in blocks:
        if block.get("is_redacted"):
            continue
        text = str(block.get("text") or "").strip()
        bbox = block.get("bbox_normalized")
        if not text or not bbox or len(bbox) != 4:
            continue
        try:
            x, y, w, h = (float(v) for v in bbox)
        except (TypeError, ValueError):
            continue
        if w <= 0 or h <= 0:
            continue
        lines.append(_Line(text=text, left=x, right=x + w, top=1.0 - (y + h), height=h))

    if not lines:
        return []

    lines.sort(key=lambda l: (round(l.top, 3), l.left))

    # If the user edited the page's text as a whole, the blocks no longer describe
    # the page — exporting them would silently discard the edits. Fall back to
    # plain mode unless the block text still matches the display text line-for-line.
    edited = page_data.get("edited_text")
    if edited:
        block_lines = [l.text for l in lines]
        edited_lines = [s.strip() for s in str(edited).splitlines() if s.strip()]
        if block_lines != edited_lines:
            return []

    return lines


def _fit_margins(doc: Document, lines: list[_Line]) -> None:
    """Match the document margins to where the scanned text actually sits."""
    if not lines:
        return
    lefts = sorted(l.left for l in lines)
    rights = sorted(l.right for l in lines)
    # 10th percentile resists stray marks at the page edge.
    left = lefts[len(lefts) // 10]
    right = rights[(len(rights) * 9) // 10]
    section = doc.sections[0]
    section.left_margin = Inches(min(max(left * _PAGE_WIDTH_IN, 0.4), 1.25))
    section.right_margin = Inches(min(max((1.0 - right) * _PAGE_WIDTH_IN, 0.4), 1.25))


def _render_layout_page(doc: Document, lines: list[_Line]) -> None:
    body_height = statistics.median(l.height for l in lines)
    column_width = max((l.width for l in lines), default=0.0)
    page_left = min(l.left for l in lines)

    paragraphs = _group_paragraphs(lines, body_height, column_width)
    for para_lines, gap_after in paragraphs:
        size = statistics.median(l.height for l in para_lines)
        font_pt = min(max(size * _PAGE_HEIGHT_PT * _FONT_FACTOR, 6.0), 72.0)
        is_heading = size >= body_height * 1.25 and len(para_lines) <= 3

        paragraph = doc.add_paragraph()
        paragraph.alignment = _alignment(para_lines)

        if paragraph.alignment == WD_ALIGN_PARAGRAPH.LEFT:
            indent = (min(l.left for l in para_lines) - page_left) * _PAGE_WIDTH_IN
            if indent > 0.08:
                paragraph.paragraph_format.left_indent = Inches(min(indent, 3.0))

        run = paragraph.add_run(" ".join(l.text for l in para_lines))
        run.font.size = Pt(round(font_pt * 2) / 2)
        if is_heading:
            run.font.bold = True

        paragraph.paragraph_format.space_after = Pt(14 if gap_after else 6)


def _group_paragraphs(
    lines: list[_Line], body_height: float, column_width: float
) -> list[tuple[list[_Line], bool]]:
    """Group reading-order lines into paragraphs; flag big gaps for extra spacing."""
    groups: list[tuple[list[_Line], bool]] = []
    current: list[_Line] = [lines[0]]

    for prev, cur in zip(lines, lines[1:]):
        gap = cur.top - prev.top
        size_change = abs(cur.height - prev.height) > body_height * 0.25
        short_prev = column_width > 0 and prev.width < column_width * 0.55
        align_change = _line_alignment(cur) != _line_alignment(prev)

        if gap > body_height * 1.7 or size_change or short_prev or align_change:
            groups.append((current, gap > body_height * 2.6))
            current = [cur]
        else:
            current.append(cur)
    groups.append((current, False))
    return groups


def _line_alignment(line: _Line) -> int:
    if abs(line.center - 0.5) < 0.05 and line.left > 0.12:
        return 1  # centered
    if line.left > 0.55 and line.right > 0.88:
        return 2  # right
    return 0


def _alignment(para_lines: list[_Line]) -> WD_ALIGN_PARAGRAPH:
    votes = [_line_alignment(l) for l in para_lines]
    majority = max(set(votes), key=votes.count)
    if majority == 1:
        return WD_ALIGN_PARAGRAPH.CENTER
    if majority == 2:
        return WD_ALIGN_PARAGRAPH.RIGHT
    return WD_ALIGN_PARAGRAPH.LEFT
