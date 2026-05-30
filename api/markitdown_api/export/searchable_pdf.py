"""Build searchable PDFs by embedding an invisible OCR text layer with PyMuPDF."""

from __future__ import annotations

import io
from typing import Any

import pymupdf


class SearchablePDFError(Exception):
    pass


def _page_text(page_data: dict[str, Any]) -> str:
    # Prefer redaction-aware export text when the client provides it.
    export = page_data.get("export_text")
    if export is not None and str(export).strip():
        return str(export)
    edited = page_data.get("edited_text")
    if edited is not None and str(edited).strip():
        return str(edited)
    return str(page_data.get("ocr_text") or "")


def _block_rect(bbox: list[Any], page_rect: "pymupdf.Rect") -> "pymupdf.Rect | None":
    if not bbox or len(bbox) != 4:
        return None
    min_x, min_y, width, height = (float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3]))
    # Vision: normalized, origin bottom-left → PyMuPDF points, origin top-left
    x0 = min_x * page_rect.width
    y1 = (1.0 - min_y) * page_rect.height
    x1 = (min_x + width) * page_rect.width
    y0 = (1.0 - (min_y + height)) * page_rect.height
    box = pymupdf.Rect(x0, y0, x1, y1)
    if box.is_empty or box.width < 1 or box.height < 1:
        return None
    return box


def _draw_redaction_box(page: pymupdf.Page, block: dict[str, Any], page_rect: pymupdf.Rect) -> None:
    """Paint an opaque black rectangle over a redacted region in the output PDF."""
    box = _block_rect(block.get("bbox_normalized"), page_rect)
    if box is None:
        return
    page.draw_rect(box, color=(0, 0, 0), fill=(0, 0, 0), width=0)


def _insert_block_text(page: pymupdf.Page, block: dict[str, Any], page_rect: pymupdf.Rect) -> None:
    text = str(block.get("text") or "").strip()
    if not text:
        return

    bbox = block.get("bbox_normalized")
    if not bbox or len(bbox) != 4:
        return

    min_x, min_y, width, height = (float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3]))
    # Vision: normalized, origin bottom-left → PyMuPDF points, origin top-left
    x0 = min_x * page_rect.width
    y1 = (1.0 - min_y) * page_rect.height
    x1 = (min_x + width) * page_rect.width
    y0 = (1.0 - (min_y + height)) * page_rect.height

    box = pymupdf.Rect(x0, y0, x1, y1)
    if box.is_empty or box.width < 1 or box.height < 1:
        return

    fontsize = max(6.0, min(box.height * 0.75, 14.0))
    page.insert_textbox(
        box,
        text,
        fontsize=fontsize,
        color=(1, 1, 1),
        fill=(1, 1, 1),
        render_mode=3,
    )


def _insert_page_textbox(page: pymupdf.Page, text: str) -> None:
    cleaned = text.strip()
    if not cleaned:
        return
    rect = page.rect
    margin = 36.0
    box = pymupdf.Rect(margin, margin, rect.width - margin, rect.height - margin)
    page.insert_textbox(
        box,
        cleaned,
        fontsize=8,
        color=(1, 1, 1),
        fill=(1, 1, 1),
        render_mode=3,
    )


def build_searchable_pdf(pdf_bytes: bytes, pages: list[dict[str, Any]]) -> bytes:
    """Embed invisible OCR text for each page that has recognition data."""
    if not pages:
        raise SearchablePDFError("No OCR pages provided")

    try:
        doc = pymupdf.open(stream=pdf_bytes, filetype="pdf")
    except Exception as exc:
        raise SearchablePDFError(f"Invalid PDF: {exc}") from exc

    pages_by_number = {int(p["page_number"]): p for p in pages if "page_number" in p}
    if not pages_by_number:
        doc.close()
        raise SearchablePDFError("No valid page numbers in OCR data")

    for page_number, page_data in sorted(pages_by_number.items()):
        index = page_number - 1
        if index < 0 or index >= doc.page_count:
            continue

        page = doc[index]
        rect = page.rect
        blocks = page_data.get("blocks") or []
        ocr_text = str(page_data.get("ocr_text") or "")
        display = _page_text(page_data)

        # Visual redaction: paint over redacted regions in the output.
        for block in blocks:
            if block.get("is_redacted") and block.get("bbox_normalized"):
                _draw_redaction_box(page, block, rect)

        non_redacted = [b for b in blocks if b.get("bbox_normalized") and not b.get("is_redacted")]
        used_blocks = False
        if non_redacted and display.strip() == ocr_text.strip():
            for block in non_redacted:
                _insert_block_text(page, block, rect)
                used_blocks = True

        if not used_blocks:
            _insert_page_textbox(page, display)

    out = io.BytesIO()
    doc.save(out, garbage=4, deflate=True)
    doc.close()
    return out.getvalue()


def build_searchable_pdf_from_image(image_bytes: bytes, page_data: dict[str, Any]) -> bytes:
    """Wrap a single image in a PDF page and add OCR text layer."""
    doc = pymupdf.open()
    page = doc.new_page(width=595, height=842)
    rect = page.rect

    try:
        page.insert_image(rect, stream=image_bytes)
    except Exception as exc:
        doc.close()
        raise SearchablePDFError(f"Invalid image: {exc}") from exc

    blocks = page_data.get("blocks") or []
    display = _page_text(page_data)
    ocr_text = str(page_data.get("ocr_text") or "")

    for block in blocks:
        if block.get("is_redacted") and block.get("bbox_normalized"):
            _draw_redaction_box(page, block, rect)

    non_redacted = [b for b in blocks if b.get("bbox_normalized") and not b.get("is_redacted")]
    used_blocks = False
    if non_redacted and display.strip() == ocr_text.strip():
        for block in non_redacted:
            _insert_block_text(page, block, rect)
            used_blocks = True

    if not used_blocks:
        _insert_page_textbox(page, display)

    out = io.BytesIO()
    doc.save(out, garbage=4, deflate=True)
    doc.close()
    return out.getvalue()
