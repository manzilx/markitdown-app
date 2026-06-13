"""Build a Markdown document from OCR page data.

Reuses the geometry layout engine from :mod:`markitdown_api.export.docx` so the
Markdown output carries the same structure the DOCX export reconstructs:

- size tiers and ALL-CAPS section titles become ATX headings (``#``/``##``/``###``)
- bullet / numbered runs become Markdown lists (source ordinal values preserved)
- aligned side-by-side rows become GitHub-flavoured pipe tables, with pure-number
  columns right-aligned (``---:``)
- everything else is flowing paragraph text, pages separated by a ``---`` rule

Plain mode (no usable geometry, or the page was edited as whole text) falls back
to a line-per-paragraph dump under a title / per-page headings, like the DOCX path.
"""

from __future__ import annotations

from typing import Any

from markitdown_api.export.docx import (
    _BULLET_CHARS,
    _Line,
    _Row,
    _assign_size_classes,
    _body_point_size,
    _column_anchors,
    _group_paragraphs,
    _group_rows,
    _heading_levels,
    _is_caps_text,
    _is_numeric_cell,
    _layout_lines,
    _list_marker,
    _nearest_anchor,
    _segment_rows,
    _split_list_segments,
)
from markitdown_api.export.searchable_pdf import _page_text


class MarkdownExportError(Exception):
    pass


def build_markdown(pages: list[dict[str, Any]], title: str = "OCR Export") -> str:
    """Create Markdown text from OCR pages, using edited_text when present."""
    if not isinstance(pages, list) or not pages:
        raise MarkdownExportError("No OCR pages provided")

    pages_by_number = sorted(
        (p for p in pages if "page_number" in p),
        key=lambda p: int(p["page_number"]),
    )
    if not pages_by_number:
        raise MarkdownExportError("No valid page numbers in OCR data")

    page_lines = [_layout_lines(p) for p in pages_by_number]
    if not any(page_lines):
        return _build_plain(pages_by_number, title)

    all_lines = [line for lines in page_lines if lines for line in lines]
    _assign_size_classes(all_lines)

    blocks: list[str] = []
    for page_data, lines in zip(pages_by_number, page_lines):
        text = _page_text(page_data).strip()
        if not text and not lines:
            continue
        if blocks:
            blocks.append("---")  # page break
        if lines:
            blocks.extend(_render_layout_page(lines))
        else:
            blocks.extend(text.splitlines())

    return _join(blocks)


def _build_plain(pages_by_number: list[dict[str, Any]], title: str) -> str:
    blocks: list[str] = [f"# {title}"]
    multi_page = len(pages_by_number) > 1
    for page_data in pages_by_number:
        page_number = int(page_data["page_number"])
        text = _page_text(page_data).strip()
        if not text:
            continue
        if multi_page:
            blocks.append(f"## Page {page_number}")
        blocks.extend(text.splitlines())
    return _join(blocks)


def _join(blocks: list[str]) -> str:
    """One blank line between blocks; collapse runs of blanks."""
    out: list[str] = []
    for block in blocks:
        block = block.rstrip()
        if not block:
            continue
        if out:
            out.append("")
        out.append(block)
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- rendering

def _render_layout_page(lines: list[_Line]) -> list[str]:
    body_pt = _body_point_size(lines)
    heading_levels = _heading_levels(lines, body_pt)
    caps_level = 1 if not heading_levels else min(max(heading_levels.values()) + 1, 3)
    column_width = max((l.width for l in lines), default=0.0)

    blocks: list[str] = []
    rows = _group_rows(lines)
    for kind, seg_rows in _segment_rows(rows):
        if kind == "table":
            blocks.append(_md_table(seg_rows))
            continue
        seg_lines = [cell for row in seg_rows for cell in row.cells]
        blocks.extend(_md_prose(seg_lines, body_pt, heading_levels, caps_level, column_width))
    return blocks


def _md_prose(
    lines: list[_Line],
    body_pt: float,
    heading_levels: dict[float, int],
    caps_level: int,
    column_width: float,
) -> list[str]:
    blocks: list[str] = []
    for kind, seg in _split_list_segments(lines):
        if kind == "list":
            blocks.append(_md_list(seg))
            continue
        for para_lines, _gap in _group_paragraphs(seg, column_width):
            sizes = [l.font_pt for l in para_lines]
            font_pt = max(set(sizes), key=sizes.count)
            level = heading_levels.get(font_pt) if len(para_lines) <= 3 else None
            if level is None and len(para_lines) == 1 and _is_caps_text(para_lines[0].text):
                level = caps_level
            text = " ".join(l.text for l in para_lines).strip()
            blocks.append(f"{'#' * level} {text}" if level else text)
    return blocks


def _md_list(lines: list[_Line]) -> str:
    items: list[list[_Line]] = []
    for line in lines:
        if _list_marker(line.text) is not None or not items:
            items.append([line])
        else:
            items[-1].append(line)

    rows: list[str] = []
    for item_lines in items:
        marker_body = _list_marker(item_lines[0].text)
        marker, first = marker_body if marker_body else ("-", item_lines[0].text)
        body = " ".join([first, *(l.text for l in item_lines[1:])]).strip()
        # Bullet glyphs normalise to '-'; ordinals (1. / 2) / a.) keep their value.
        md_marker = "-" if len(marker) == 1 and marker in _BULLET_CHARS else marker
        rows.append(f"{md_marker} {body}")
    return "\n".join(rows)


def _md_cell(text: str) -> str:
    """Escape a value for a GFM table cell: a literal '|' is the column delimiter and
    would otherwise split the cell into extra columns; newlines would break the row."""
    return text.replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ").replace("\r", " ").strip()


def _md_table(rows: list[_Row]) -> str:
    real_rows = [r for r in rows if r.is_multi_cell]
    uniform = len({len(r.cells) for r in real_rows}) == 1
    anchors = (
        [min(r.cells[i].left for r in real_rows) for i in range(len(real_rows[0].cells))]
        if uniform
        else _column_anchors(real_rows)
    )
    ncols = len(anchors)

    grid: list[dict[int, list[str]]] = []
    for row in rows:
        if row.tag == "cont" and grid:
            line = row.cells[0]
            grid[-1].setdefault(_nearest_anchor(anchors, line.left), []).append(line.text)
            continue
        if row.tag == "divider":
            grid.append({-1: [c.text for c in row.cells]})
            continue
        entry: dict[int, list[str]] = {}
        if uniform and row.is_multi_cell:
            for i, cell_line in enumerate(row.cells):
                entry.setdefault(min(i, ncols - 1), []).append(cell_line.text)
        else:
            for cell_line in row.cells:
                entry.setdefault(_nearest_anchor(anchors, cell_line.left), []).append(cell_line.text)
        grid.append(entry)

    numeric_cols: set[int] = set()
    for col in range(ncols):
        texts = [t for entry in grid if -1 not in entry for t in entry.get(col, []) if t.strip()]
        if len(texts) >= 2 and sum(_is_numeric_cell(t) for t in texts) >= 0.8 * len(texts):
            numeric_cols.add(col)

    def render_row(entry: dict[int, list[str]]) -> str:
        if -1 in entry:  # spanning divider: bold text in col 0, GFM has no rowspan
            cells = ["**" + _md_cell(" ".join(entry[-1])) + "**"] + [""] * (ncols - 1)
        else:
            cells = [_md_cell(" ".join(entry.get(c, []))) for c in range(ncols)]
        return "| " + " | ".join(cells) + " |"

    sep = "| " + " | ".join("---:" if c in numeric_cols else "---" for c in range(ncols)) + " |"

    # GFM requires a header row; use the first grid row, separator, then the rest.
    out = [render_row(grid[0]), sep]
    out.extend(render_row(entry) for entry in grid[1:])
    return "\n".join(out)
