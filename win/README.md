# OCR Review — Windows

Native Windows desktop app matching the macOS **OCR Review** workflow.

## For users (no dev tools)

**You do not need Node, Rust, Python, or uv.**

1. Download `OCR Review_*_x64-setup.exe` (from GitHub Actions artifact or a release)
2. Run the installer
3. Open **OCR Review** from the Start menu

See **[GET-STARTED.md](./GET-STARTED.md)** for details.

The installer bundles:
- The OCR Review app
- The export engine (Word + searchable PDF) — no Python install
- WebView2 bootstrapper on Windows 10 if needed

---

## For developers (build from source)

Only needed if you’re modifying the app — **not** for normal use.

| Tool | Purpose |
|------|---------|
| Node.js 20+ | Build UI |
| Rust | Build app shell |
| Python 3.12 + uv | Build bundled sidecar (CI does this automatically) |

```powershell
# Full build (Windows PC or CI)
cd markitdown-app
.\scripts\build-windows-sidecar.ps1   # bundles export engine
cd win
npm install
npm run tauri:build
```

Outputs:
- `win\src-tauri\target\release\ocr-review.exe`
- `win\src-tauri\target\release\bundle\nsis\OCR Review_1.0.0_x64-setup.exe`

---

## macOS vs Windows

| macOS | Windows |
|-------|---------|
| Apple Vision OCR | Windows OCR (built-in) |
| Python sidecar via `uv` (dev) | Bundled `ocr-sidecar.exe` (users) |

---

## CI build (no local Windows needed)

Push to GitHub and run workflow **Build Windows** → download artifact **OCR-Review-Windows**.

```bash
make win-ci
```
