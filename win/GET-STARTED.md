# OCR Review for Windows — Getting Started

You do **not** need Node, Rust, Python, or uv on your laptop.

Those tools are only for developers building from source. As a user, you only install one app.

---

## Step 1 — Download the installer

Get **`OCR Review_1.0.0_x64-setup.exe`** from one of:

1. **GitHub Actions** (if the repo is on GitHub): Actions → **Build Windows** → download artifact **OCR-Review-Windows**
2. **Someone who built it** and sent you the `.exe`

---

## Step 2 — Install

1. Double-click the setup file
2. Click through the installer (Next → Install → Finish)
3. Open **OCR Review** from the Start menu

That’s it.

---

## What runs without installing anything else

| Feature | Needs extra installs? |
|---------|------------------------|
| Open PDF / images | No |
| Windows OCR (on-device) | No |
| Recognize one page or all pages | No |
| Cancel long OCR runs while keeping completed pages | No |
| Review & edit text | No |
| Jump-to-issue, heatmap | No |
| Find / replace | No |
| Denoise repeated page numbers, headers, and footers | No |
| Export Markdown | No |
| Export text (.txt) | No |
| Export Word (.docx) | No — export engine is bundled in the installer |
| Export searchable PDF | No — export engine is bundled in the installer |
| Recover saved work from snapshots | No |

The installer includes a bundled **export engine** (`ocr-sidecar.exe`). You never install Python or uv.

---

## Windows 10 note

Windows 11 already has **WebView2**. On Windows 10, the installer includes a small WebView2 bootstrapper if needed (one-time, automatic during setup).

---

## If something goes wrong

1. **App won’t open** — Run Windows Update; ensure you’re on Windows 10 1809+ or Windows 11
2. **Word / searchable PDF export fails** — Settings → **Restart Sidecar**, then try again
3. **Still stuck** — Reinstall from the setup `.exe`

---

## For developers only (not required for users)

```powershell
cd markitdown-app
.\scripts\build-windows-sidecar.ps1
cd win
npm install
npm run tauri:build
```

See [README.md](./README.md) for full dev setup.
