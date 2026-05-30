"""Raise Starlette's default 1MB multipart part limit for large PDF uploads."""

from __future__ import annotations

from starlette.requests import Request

from markitdown_api.config import MAX_MULTIPART_PART_BYTES

_original_get_form = Request._get_form


async def _get_form_with_large_parts(
    self: Request,
    *,
    max_files: int = 1000,
    max_fields: int = 1000,
    max_part_size: int = 1024 * 1024,
) -> object:
    return await _original_get_form(
        self,
        max_files=max_files,
        max_fields=max_fields,
        max_part_size=MAX_MULTIPART_PART_BYTES,
    )


def apply_multipart_limit_patch() -> None:
    Request._get_form = _get_form_with_large_parts  # type: ignore[method-assign]
