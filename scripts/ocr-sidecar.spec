# PyInstaller spec — builds a standalone sidecar .exe for Windows (no Python install needed).
# Run from repo root on Windows: pyinstaller scripts/ocr-sidecar.spec

import sys
from pathlib import Path

root = Path(SPECPATH).parent
api_dir = root / "api"

a = Analysis(
    [str(api_dir / "run_sidecar.py")],
    pathex=[str(api_dir)],
    binaries=[],
    datas=[],
    hiddenimports=[
        "uvicorn",
        "uvicorn.logging",
        "uvicorn.loops",
        "uvicorn.loops.auto",
        "uvicorn.protocols",
        "uvicorn.protocols.http",
        "uvicorn.protocols.http.auto",
        "uvicorn.protocols.websockets",
        "uvicorn.protocols.websockets.auto",
        "uvicorn.lifespan",
        "uvicorn.lifespan.on",
        "fastapi",
        "starlette",
        "starlette.routing",
        "multipart",
        "markitdown_api.main",
        "markitdown_api.config",
        "markitdown_api.converter",
        "markitdown_api.export_routes",
        "markitdown_api.pdf_routes",
        "markitdown_api.pdf_tools",
        "markitdown_api.multipart_limits",
        "pydantic",
        "pymupdf",
        "fitz",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="ocr-sidecar",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
