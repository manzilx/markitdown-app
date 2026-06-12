"""HTTP-facing safety helpers."""

from __future__ import annotations

import re
from urllib.parse import quote

from fastapi import UploadFile


class UploadTooLargeError(Exception):
    def __init__(self, limit_bytes: int) -> None:
        self.limit_bytes = limit_bytes
        super().__init__(f"Upload exceeds {limit_bytes} bytes")


async def read_upload_limited(
    upload: UploadFile,
    limit_bytes: int,
    *,
    chunk_size: int = 1024 * 1024,
) -> bytes:
    """Read an UploadFile without letting one request grow memory unbounded."""
    chunks: list[bytes] = []
    total = 0

    while True:
        chunk = await upload.read(chunk_size)
        if not chunk:
            break

        total += len(chunk)
        if total > limit_bytes:
            raise UploadTooLargeError(limit_bytes)
        chunks.append(chunk)

    return b"".join(chunks)


_UNSAFE_FILENAME_CHARS = re.compile(r"[\x00-\x1f\x7f\"\\/:*?<>|;]+")
_SAFE_ASCII_CHARS = re.compile(r"[^A-Za-z0-9._ -]+")


def safe_download_filename(filename: str, *, default: str = "download", max_length: int = 120) -> str:
    cleaned = _UNSAFE_FILENAME_CHARS.sub("_", filename).strip(" ._")
    if not cleaned:
        cleaned = default
    return cleaned[:max_length].strip(" ._") or default


def attachment_headers(filename: str) -> dict[str, str]:
    safe_name = safe_download_filename(filename)
    ascii_name = safe_name.encode("ascii", "ignore").decode()
    ascii_name = _SAFE_ASCII_CHARS.sub("_", ascii_name).strip(" ._") or "download"
    return {
        "Content-Disposition": (
            f'attachment; filename="{ascii_name}"; filename*=UTF-8\'\'{quote(safe_name)}'
        )
    }
