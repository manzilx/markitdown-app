"""Tests for MarkItDown standalone API."""

from __future__ import annotations

import io

import pytest
from fastapi.testclient import TestClient

from markitdown_api.config import MAX_UPLOAD_BYTES, get_settings
from markitdown_api.main import app


@pytest.fixture
def client() -> TestClient:
    get_settings.cache_clear()
    return TestClient(app)


def test_health(client: TestClient) -> None:
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_list_engines(client: TestClient) -> None:
    resp = client.get("/v1/engines")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["engines"]) == 4
    ids = {e["id"] for e in data["engines"]}
    assert ids == {"builtin", "azure_doc_intel", "pymupdf4llm", "ocr_plugin"}
    builtin = next(e for e in data["engines"] if e["id"] == "builtin")
    assert builtin["available"] is True


def test_convert_txt_builtin(client: TestClient) -> None:
    content = b"Hello MarkItDown\n\nSecond paragraph."
    resp = client.post(
        "/v1/convert",
        files={"file": ("notes.txt", io.BytesIO(content), "text/plain")},
        data={"engine": "builtin"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["engine"] == "builtin"
    assert "Hello MarkItDown" in body["markdown"]


def test_convert_csv_builtin(client: TestClient) -> None:
    content = b"name,value\nfoo,1\nbar,2\n"
    resp = client.post(
        "/v1/convert",
        files={"file": ("data.csv", io.BytesIO(content), "text/csv")},
        data={"engine": "builtin"},
    )
    assert resp.status_code == 200
    assert "foo" in resp.json()["markdown"]


def test_unsupported_extension(client: TestClient) -> None:
    resp = client.post(
        "/v1/convert",
        files={"file": ("bad.exe", io.BytesIO(b"x"), "application/octet-stream")},
        data={"engine": "builtin"},
    )
    assert resp.status_code == 415


def test_oversize_payload(client: TestClient) -> None:
    big = b"x" * (MAX_UPLOAD_BYTES + 1)
    resp = client.post(
        "/v1/convert",
        files={"file": ("big.txt", io.BytesIO(big), "text/plain")},
        data={"engine": "builtin"},
    )
    assert resp.status_code == 413


def test_unavailable_engine(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("MARKITDOWN_DOCINTEL_ENDPOINT", raising=False)
    get_settings.cache_clear()
    resp = client.post(
        "/v1/convert",
        files={"file": ("notes.txt", io.BytesIO(b"hi"), "text/plain")},
        data={"engine": "azure_doc_intel"},
    )
    assert resp.status_code == 503


def test_unknown_engine(client: TestClient) -> None:
    resp = client.post(
        "/v1/convert",
        files={"file": ("notes.txt", io.BytesIO(b"hi"), "text/plain")},
        data={"engine": "not-a-real-engine"},
    )
    assert resp.status_code == 422
