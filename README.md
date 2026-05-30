# MarkItDown / OCR Review

Native **macOS app** (SwiftUI) for Adobe-style OCR review and export — plus a Python engine sidecar and optional web dev UI.

See **[plan.md](./plan.md)** for the full product roadmap.

## Prerequisites

- macOS 14+, Xcode 15+
- Python 3.12+ and [uv](https://docs.astral.sh/uv/) (engine sidecar)
- Node.js 20+ (optional web dev UI)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — after Phase 1

## Quick start (engine sidecar — optional)

Advanced engines (Azure, PyMuPDF, LLM OCR) use the Python API:

```bash
cd ~/markitdown-app
make install
cp .env.example .env   # optional
make api               # http://localhost:8001
```

## macOS app (Phase 1 — in development)

```bash
make mac-gen
make mac               # opens Xcode → Run
```

Default OCR uses **Apple Vision** on-device — no sidecar required.

**Searchable PDF export** and **Word export** require the Python sidecar:

```bash
make api    # terminal — keep running
```

Then in the app: **Export Searchable PDF…** or **Export Word…** (OCR at least one page first).

**Find & replace:** ⌘F opens the find bar; searches and replaces across all OCR'd pages.

**Engine picker:** OCR Review → Settings — choose Apple Vision (default) or a sidecar engine (Azure, PyMuPDF4LLM, etc.).

**Sidecar auto-start:** The macOS app launches the Python API on startup (no Terminal needed if `~/markitdown-app` exists and `uv` is installed). Override path in Settings.

## Optional web dev UI

```bash
cd web && npm install && npm run dev
# http://localhost:5174
```

## Layout

```
mac/          SwiftUI macOS app (primary product)
api/          Python FastAPI sidecar (advanced engines)
web/          React dev UI (optional)
tests/        API tests
plan.md       Product & engineering plan
```
