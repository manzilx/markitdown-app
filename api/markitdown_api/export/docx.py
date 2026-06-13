"""Build Word documents from OCR page data.

Two modes per page:

- **Layout mode** (page has block geometry): reconstruct the original document's
  look from the OCR bounding boxes — side-by-side lines become real Word tables
  (columns clustered across consecutive rows, widths from geometry), font sizes
  are quantized into document-wide classes derived from line heights, oversized
  lines are bolded as headings, centered/right alignment is detected from block
  positions, paragraphs are grouped by vertical gaps, indents and margins are
  preserved, and pages are separated by real page breaks. No artificial "Page N"
  headings.
- **Plain mode** (no usable geometry, or the user edited the page's text as a
  whole so the blocks no longer describe it): the legacy line-per-paragraph dump
  with the document title and per-page headings.
"""

from __future__ import annotations

import io
import re
import statistics
from dataclasses import dataclass, field
from typing import Any

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT
from docx.shared import Inches, Pt, RGBColor

from markitdown_api.export.payload import ExportPayloadError, normalize_export_pages
from markitdown_api.export.searchable_pdf import _page_text


class DOCXExportError(Exception):
    pass


# US-Letter reference frame for converting normalized geometry to points/inches.
_PAGE_HEIGHT_PT = 792.0
_PAGE_WIDTH_IN = 8.5
# Empirical: a text line's bbox (ascender to descender) is ~1.2x the font size.
_FONT_FACTOR = 0.85
# Two cells on the same visual row must be separated by at least this much
# horizontally to count as table columns (filters touching/overlapping boxes).
_MIN_CELL_GAP = 0.02
# Left edges within this distance are treated as the same column.
_COLUMN_TOLERANCE = 0.06

# Leading list markers, kept verbatim in the export so numbering/bullets match the
# source exactly (Word auto-numbering would renumber and lose the original values).
_BULLET_CHARS = "•◦‣·▪◆●○*–—-"
_BULLET_RE = re.compile(rf"^\s*([{re.escape(_BULLET_CHARS)}])\s+(\S.*)$")
_NUMBER_RE = re.compile(
    r"^\s*(\(?(?:\d{1,3}|[a-zA-Z]|(?:i{1,3}|iv|v|vi{0,3}|ix|x|xi{0,3}))[.)])\s+(\S.*)$"
)


@dataclass
class _Line:
    text: str
    left: float    # normalized, from page left
    right: float
    top: float     # normalized, from page TOP (flipped from Vision's bottom-left)
    height: float
    font_pt: float = 11.0  # assigned from document-wide size classes

    @property
    def bottom(self) -> float:
        return self.top + self.height

    @property
    def center(self) -> float:
        return (self.left + self.right) / 2

    @property
    def width(self) -> float:
        return self.right - self.left


@dataclass
class _Row:
    """Lines that sit side-by-side on the same visual row, left to right."""
    cells: list[_Line] = field(default_factory=list)
    top: float = 0.0
    bottom: float = 0.0
    # Set during table segmentation: "row" (normal), "cont" (wrapped-cell
    # continuation merged into the row above), "divider" (single cell spanning
    # the table, e.g. a section header between label/value runs).
    tag: str = "row"

    @property
    def height(self) -> float:
        return self.bottom - self.top

    @property
    def is_multi_cell(self) -> bool:
        if len(self.cells) < 2:
            return False
        return all(
            b.left - a.right >= _MIN_CELL_GAP
            for a, b in zip(self.cells, self.cells[1:])
        )


def build_docx(pages: list[dict[str, Any]], title: str = "OCR Export") -> bytes:
    """Create a .docx from OCR pages using edited_text when present."""
    try:
        normalized_pages = normalize_export_pages(pages)
    except ExportPayloadError as exc:
        raise DOCXExportError(str(exc)) from exc

    pages_by_number = sorted(
        normalized_pages,
        key=lambda p: int(p["page_number"]),
    )

    page_lines = [_layout_lines(p) for p in pages_by_number]
    if not any(page_lines):
        return _build_plain(pages_by_number, title)

    all_lines = [line for lines in page_lines if lines for line in lines]
    _assign_size_classes(all_lines)

    doc = Document()
    _fit_margins(doc, all_lines)

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
    try:
        doc.save(out)
    except Exception as exc:
        raise DOCXExportError("Could not save DOCX") from exc
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


# ---------------------------------------------------------------- geometry

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
        block_lines = sorted(l.text for l in lines)
        edited_lines = sorted(s.strip() for s in str(edited).splitlines() if s.strip())
        if block_lines != edited_lines:
            return []

    return lines


def _assign_size_classes(lines: list[_Line]) -> None:
    """Quantize line heights into document-wide font sizes.

    Raw OCR heights jitter line to line (10.4pt, 11.1pt, 10.8pt…), which exported
    as visibly inconsistent body text. Cluster heights within 18% and give every
    member of a cluster the same point size.
    """
    if not lines:
        return
    heights = sorted(l.height for l in lines)
    clusters: list[list[float]] = [[heights[0]]]
    for h in heights[1:]:
        if h <= clusters[-1][0] * 1.18:
            clusters[-1].append(h)
        else:
            clusters.append([h])

    bounds_and_pt = []
    for cluster in clusters:
        median_h = statistics.median(cluster)
        pt = min(max(median_h * _PAGE_HEIGHT_PT * _FONT_FACTOR, 6.0), 72.0)
        bounds_and_pt.append((cluster[0], cluster[-1], round(pt * 2) / 2))

    for line in lines:
        for low, high, pt in bounds_and_pt:
            if low <= line.height <= high:
                line.font_pt = pt
                break
        else:
            line.font_pt = round(
                min(max(line.height * _PAGE_HEIGHT_PT * _FONT_FACTOR, 6.0), 72.0) * 2
            ) / 2


def _group_rows(lines: list[_Line]) -> list[_Row]:
    """Group reading-order lines into visual rows by vertical overlap."""
    rows: list[_Row] = []
    for line in lines:
        if rows:
            row = rows[-1]
            overlap = min(row.bottom, line.bottom) - max(row.top, line.top)
            if overlap >= 0.5 * min(row.height, line.height):
                row.cells.append(line)
                row.top = min(row.top, line.top)
                row.bottom = max(row.bottom, line.bottom)
                continue
        rows.append(_Row(cells=[line], top=line.top, bottom=line.bottom))

    for row in rows:
        row.cells.sort(key=lambda l: l.left)
    return rows


def _edges_align(a: _Line, b: _Line) -> bool:
    """Same column if LEFT edges align (text columns) or RIGHT edges align
    (numeric columns in invoices/financials are right-aligned — their left
    edges scatter with the number width)."""
    return (
        abs(a.left - b.left) <= _COLUMN_TOLERANCE
        or abs(a.right - b.right) <= _COLUMN_TOLERANCE
    )


def _columns_align(a: _Row, b: _Row) -> bool:
    """Do two multi-cell rows share a column structure?"""
    smaller, larger = (a.cells, b.cells) if len(a.cells) <= len(b.cells) else (b.cells, a.cells)
    matched = sum(
        1 for cell in smaller
        if any(_edges_align(cell, other) for other in larger)
    )
    return matched >= max(2, len(smaller) - 1)


def _is_continuation(row: _Row, run: list[_Row]) -> bool:
    """A wrapped cell: a single line directly below the previous row, sitting at a
    non-first column anchor — the rest of a value that didn't fit on one line."""
    if len(row.cells) != 1:
        return False
    cell = row.cells[0]
    anchors = _column_anchors(run)
    col = _nearest_anchor(anchors, cell.left)
    if col == 0 or abs(anchors[col] - cell.left) > _COLUMN_TOLERANCE:
        return False
    gap = row.top - run[-1].bottom
    return gap <= max(run[-1].height, 0.012) * 1.2


def _is_divider(row: _Row, run: list[_Row], nxt: _Row | None) -> bool:
    """A section header INSIDE a table: a single cell sandwiched between aligned
    multi-cell rows (registry extracts break label/value runs with these). Only
    absorbed when an aligned row follows — a trailing single cell is a footer."""
    if len(row.cells) != 1 or nxt is None or not nxt.is_multi_cell:
        return False
    last_real = next(r for r in reversed(run) if r.is_multi_cell)
    if not _columns_align(last_real, nxt):
        return False
    gap = row.top - run[-1].bottom
    return gap <= max(run[-1].height, 0.012) * 2.5


def _segment_rows(rows: list[_Row]) -> list[tuple[str, list[_Row]]]:
    """Split rows into ('table', …) runs (≥2 aligned multi-cell rows, plus any
    wrapped-cell continuation lines and spanning divider rows) and ('text', …)."""
    segments: list[tuple[str, list[_Row]]] = []
    i = 0
    while i < len(rows):
        if rows[i].is_multi_cell:
            run = [rows[i]]
            j = i + 1
            while j < len(rows):
                last_real = next(r for r in reversed(run) if r.is_multi_cell)
                if rows[j].is_multi_cell and _columns_align(last_real, rows[j]):
                    run.append(rows[j])
                elif _is_continuation(rows[j], run):
                    rows[j].tag = "cont"
                    run.append(rows[j])
                elif _is_divider(rows[j], run, rows[j + 1] if j + 1 < len(rows) else None):
                    rows[j].tag = "divider"
                    run.append(rows[j])
                else:
                    break
                j += 1
            if sum(1 for r in run if r.is_multi_cell) >= 2:
                segments.append(("table", run))
                i = j
                continue
        if segments and segments[-1][0] == "text":
            segments[-1][1].append(rows[i])
        else:
            segments.append(("text", [rows[i]]))
        i += 1
    return segments


# ---------------------------------------------------------------- rendering

def _render_layout_page(doc: Document, lines: list[_Line]) -> None:
    body_pt = _body_point_size(lines)
    heading_levels = _heading_levels(lines, body_pt)
    column_width = max((l.width for l in lines), default=0.0)
    page_left = min(l.left for l in lines)

    rows = _group_rows(lines)
    for kind, seg_rows in _segment_rows(rows):
        if kind == "table":
            _emit_table(doc, seg_rows)
            continue
        # Isolated multi-cell rows (a lone label/value pair amid prose) keep their
        # column separation via tab stops instead of collapsing to a single space.
        buffered: list[_Line] = []
        for row in seg_rows:
            if row.is_multi_cell:
                if buffered:
                    _emit_paragraphs(doc, buffered, body_pt, heading_levels, column_width, page_left)
                    buffered = []
                _emit_tabbed_row(doc, row, page_left)
            else:
                buffered.extend(row.cells)
        if buffered:
            _emit_paragraphs(doc, buffered, body_pt, heading_levels, column_width, page_left)


def _body_point_size(lines: list[_Line]) -> float:
    sizes = [l.font_pt for l in lines]
    return max(set(sizes), key=sizes.count)


def _heading_levels(lines: list[_Line], body_pt: float) -> dict[float, int]:
    """Map each above-body font size to a Word heading level (largest → Heading 1).
    Only sizes >=1.25x body qualify as headings; tiers past the third all map to 3."""
    sizes = sorted(
        {l.font_pt for l in lines if l.font_pt >= body_pt * 1.25},
        reverse=True,
    )
    return {size: min(i + 1, 3) for i, size in enumerate(sizes)}


def _emit_table(doc: Document, rows: list[_Row]) -> None:
    """Emit aligned multi-cell rows as a borderless Word table with geometric widths.

    When every real row has the same cell count, columns are POSITIONAL (cell i →
    column i): this places right-aligned numeric columns correctly even though
    their left edges scatter. Mixed cell counts fall back to left-edge anchors.
    Single-cell continuation rows (wrapped values) merge into the previous row.
    """
    real_rows = [r for r in rows if r.is_multi_cell]
    uniform = len({len(r.cells) for r in real_rows}) == 1
    anchors = (
        [min(r.cells[i].left for r in real_rows) for i in range(len(real_rows[0].cells))]
        if uniform
        else _column_anchors(real_rows)
    )
    ncols = len(anchors)

    # Build the grid first: each entry is one table row, col -> wrapped lines.
    # Key -1 marks a divider row that spans every column.
    grid: list[dict[int, list[_Line]]] = []
    for row in rows:
        if row.tag == "cont" and grid:
            line = row.cells[0]
            col = _nearest_anchor(anchors, line.left)
            grid[-1].setdefault(col, []).append(line)
            continue
        if row.tag == "divider":
            grid.append({-1: list(row.cells)})
            continue
        entry: dict[int, list[_Line]] = {}
        if uniform and row.is_multi_cell:
            for i, cell_line in enumerate(row.cells):
                entry.setdefault(min(i, ncols - 1), []).append(cell_line)
        else:
            for cell_line in row.cells:
                entry.setdefault(_nearest_anchor(anchors, cell_line.left), []).append(cell_line)
        grid.append(entry)

    right_edge = max(c.right for row in rows for c in row.cells)
    boundaries = anchors + [right_edge]
    widths = [
        Inches(max((boundaries[i + 1] - boundaries[i]) * _PAGE_WIDTH_IN, 0.4))
        for i in range(ncols)
    ]

    table = doc.add_table(rows=len(grid), cols=ncols)
    table.autofit = False

    for r, entry in enumerate(grid):
        if -1 in entry:
            # Spanning divider row: merge across all columns, bold like a header.
            cell = table.cell(r, 0)
            if ncols > 1:
                cell = cell.merge(table.cell(r, ncols - 1))
            for k, line in enumerate(entry[-1]):
                paragraph = cell.paragraphs[0] if k == 0 else cell.add_paragraph()
                run = paragraph.add_run(line.text)
                run.font.size = Pt(line.font_pt)
                run.font.bold = True
                paragraph.paragraph_format.space_after = Pt(2)
            continue
        for col, cell_lines in entry.items():
            cell = table.cell(r, col)
            for k, line in enumerate(cell_lines):
                paragraph = cell.paragraphs[0] if k == 0 else cell.add_paragraph()
                run = paragraph.add_run(line.text)
                run.font.size = Pt(line.font_pt)
                paragraph.paragraph_format.space_after = Pt(2)
        for c, width in enumerate(widths):
            table.cell(r, c).width = width

    # Breathing room after the table.
    doc.add_paragraph().paragraph_format.space_after = Pt(4)


def _emit_tabbed_row(doc: Document, row: _Row, page_left: float) -> None:
    """One visual row whose cells stay at their geometric positions via tab stops."""
    paragraph = doc.add_paragraph()
    fmt = paragraph.paragraph_format
    indent = (row.cells[0].left - page_left) * _PAGE_WIDTH_IN
    if indent > 0.08:
        fmt.left_indent = Inches(min(indent, 3.0))
    for cell in row.cells[1:]:
        fmt.tab_stops.add_tab_stop(
            Inches(min(max((cell.left - page_left) * _PAGE_WIDTH_IN, 0.1), _PAGE_WIDTH_IN)),
            WD_TAB_ALIGNMENT.LEFT,
        )
    for k, cell in enumerate(row.cells):
        if k:
            paragraph.add_run("\t")
        run = paragraph.add_run(cell.text)
        run.font.size = Pt(cell.font_pt)
    fmt.space_after = Pt(6)


def _column_anchors(rows: list[_Row]) -> list[float]:
    lefts = sorted(c.left for row in rows for c in row.cells)
    anchors: list[float] = [lefts[0]]
    for left in lefts[1:]:
        if left - anchors[-1] > _COLUMN_TOLERANCE:
            anchors.append(left)
    return anchors


def _nearest_anchor(anchors: list[float], left: float) -> int:
    return min(range(len(anchors)), key=lambda i: abs(anchors[i] - left))


def _list_marker(text: str) -> tuple[str, str] | None:
    """If the line begins with a bullet glyph or an ordinal (1. / 2) / a. / (iv)),
    return (marker, body) with the marker preserved verbatim; else None."""
    m = _BULLET_RE.match(text)
    if m:
        return m.group(1), m.group(2).strip()
    m = _NUMBER_RE.match(text)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return None


def _split_list_segments(lines: list[_Line]) -> list[tuple[str, list[_Line]]]:
    """Partition reading-order lines into ('list', …) and ('prose', …) runs. A list
    run needs >=2 marker lines, so a lone "1. Introduction" heading or a stray dash
    stays prose. Lines with no marker that sit indented just below an item and close
    to it are absorbed as wrapped continuations of that item."""
    segments: list[tuple[str, list[_Line]]] = []
    i = 0
    n = len(lines)
    while i < n:
        if _list_marker(lines[i].text) is not None:
            item_left = lines[i].left
            run = [lines[i]]
            markers = 1
            j = i + 1
            while j < n:
                nxt = lines[j]
                if _list_marker(nxt.text) is not None:
                    run.append(nxt)
                    markers += 1
                    j += 1
                    continue
                gap = nxt.top - lines[j - 1].bottom
                if gap <= max(lines[j - 1].height, 0.012) * 1.6 and nxt.left > item_left + 0.015:
                    run.append(nxt)  # wrapped continuation, indented past the marker
                    j += 1
                    continue
                break
            if markers >= 2:
                segments.append(("list", run))
                i = j
                continue
        if segments and segments[-1][0] == "prose":
            segments[-1][1].append(lines[i])
        else:
            segments.append(("prose", [lines[i]]))
        i += 1
    return segments


def _emit_list(doc: Document, lines: list[_Line], page_left: float) -> None:
    items: list[list[_Line]] = []
    for line in lines:
        if _list_marker(line.text) is not None or not items:
            items.append([line])
        else:
            items[-1].append(line)
    for item_lines in items:
        _emit_list_item(doc, item_lines, page_left)


def _emit_list_item(doc: Document, item_lines: list[_Line], page_left: float) -> None:
    """One list item as a hanging-indent paragraph: source marker, tab, body text
    (wrapped lines folded in). The marker stays at the item's left edge; the body
    and any wrap align past it."""
    marker_body = _list_marker(item_lines[0].text)
    marker, first = marker_body if marker_body else ("", item_lines[0].text)
    body = " ".join([first, *(l.text for l in item_lines[1:])]).strip()

    sizes = [l.font_pt for l in item_lines]
    font_pt = max(set(sizes), key=sizes.count)

    paragraph = doc.add_paragraph()
    fmt = paragraph.paragraph_format
    base = min(max((item_lines[0].left - page_left) * _PAGE_WIDTH_IN, 0.0), 3.0)
    hang = 0.25
    fmt.left_indent = Inches(base + hang)
    fmt.first_line_indent = Inches(-hang)
    fmt.tab_stops.add_tab_stop(Inches(base + hang), WD_TAB_ALIGNMENT.LEFT)
    run = paragraph.add_run(f"{marker}\t{body}")
    run.font.size = Pt(font_pt)
    fmt.space_after = Pt(3)


def _emit_paragraphs(
    doc: Document,
    lines: list[_Line],
    body_pt: float,
    heading_levels: dict[float, int],
    column_width: float,
    page_left: float,
) -> None:
    if not lines:
        return
    for kind, seg in _split_list_segments(lines):
        if kind == "list":
            _emit_list(doc, seg, page_left)
        else:
            _emit_prose(doc, seg, body_pt, heading_levels, column_width, page_left)


def _emit_prose(
    doc: Document,
    lines: list[_Line],
    body_pt: float,
    heading_levels: dict[float, int],
    column_width: float,
    page_left: float,
) -> None:
    for para_lines, gap_after in _group_paragraphs(lines, column_width):
        sizes = [l.font_pt for l in para_lines]
        font_pt = max(set(sizes), key=sizes.count)
        level = heading_levels.get(font_pt) if len(para_lines) <= 3 else None

        paragraph = doc.add_paragraph()
        # A real Word heading style gives the export a navigable outline (Navigation
        # pane / auto TOC). We keep the scanned size, bold, and black colour so the
        # look matches the source rather than the template's accent-coloured default.
        if level:
            paragraph.style = doc.styles[f"Heading {level}"]
        paragraph.alignment = _alignment(para_lines)

        if paragraph.alignment == WD_ALIGN_PARAGRAPH.LEFT:
            indent = (min(l.left for l in para_lines) - page_left) * _PAGE_WIDTH_IN
            if indent > 0.08:
                paragraph.paragraph_format.left_indent = Inches(min(indent, 3.0))

        run = paragraph.add_run(" ".join(l.text for l in para_lines))
        run.font.size = Pt(font_pt)
        if level:
            run.font.bold = True
            run.font.color.rgb = RGBColor(0, 0, 0)

        paragraph.paragraph_format.space_after = Pt(14 if gap_after else 6)


def _group_paragraphs(
    lines: list[_Line], column_width: float
) -> list[tuple[list[_Line], bool]]:
    """Group reading-order lines into paragraphs; flag big gaps for extra spacing."""
    body_height = statistics.median(l.height for l in lines)
    groups: list[tuple[list[_Line], bool]] = []
    current: list[_Line] = [lines[0]]

    for prev, cur in zip(lines, lines[1:]):
        gap = cur.top - prev.top
        size_change = cur.font_pt != prev.font_pt
        short_prev = column_width > 0 and prev.width < column_width * 0.55
        align_change = _line_alignment(cur) != _line_alignment(prev)

        if gap > body_height * 1.7 or size_change or short_prev or align_change:
            groups.append((current, gap > body_height * 2.6))
            current = [cur]
        else:
            current.append(cur)
    groups.append((current, False))
    return groups


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
