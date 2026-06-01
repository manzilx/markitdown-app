# OCR Review for Windows

A native **WPF (.NET 8, C#)** port of the macOS OCR Review app. Same Acrobat-style
workflow — open a scanned PDF/image → recognize text → review & correct beside the
page → export — built on Windows-native APIs and producing a standalone **`.exe`**.

## How it maps to the macOS app

| Concern            | macOS                     | Windows                                            |
|--------------------|---------------------------|----------------------------------------------------|
| UI                 | SwiftUI                   | **WPF / XAML** (indigo design system in `Themes/Theme.xaml`) |
| On-device OCR      | Apple Vision              | **`Windows.Media.Ocr`** (free, offline, bounding boxes) |
| PDF rendering      | PDFKit                    | **`Windows.Data.Pdf`**                             |
| PDF structure edits| PDFKit                    | **PdfSharp** (rotate / reorder / merge / split / save) |
| Suspect detection  | Vision confidence         | **Hunspell** spell check (en-US dictionary embedded) — Windows OCR has no confidence scores, so misspelled lines drive the heatmap / suspect spans / jump-to-issue |
| Advanced engines + DOCX / searchable PDF | Python sidecar | **same Python sidecar** (reused unchanged) |

## Architecture

```
windows/
├── OcrReview.sln
├── src/
│   ├── OcrReview.Core/   # net8.0 — models, find, export, sidecar client, JobStore,
│   │   │                 #          spell check. Cross-platform; unit-tested on any OS.
│   │   └── Dictionaries/ # embedded en-US Hunspell dictionary
│   └── OcrReview.App/    # net8.0-windows — WPF UI, ViewModel, WinRT services (OCR, PDF render)
└── tests/OcrReview.Core.Tests/   # xUnit (runs on macOS/Linux/Windows)
```

The platform-agnostic **Core** library compiles and is unit-tested anywhere (including
in CI on a non-Windows box). The **App** (WPF + WinRT) only builds on Windows.

## Getting the .exe

**Option A — GitHub Actions (no Windows machine needed).** Push the repo; the
[`Windows app`](../.github/workflows/windows-build.yml) workflow builds on a
`windows-latest` runner and uploads `OcrReview.exe` as an artifact. Trigger it
manually from the Actions tab (`workflow_dispatch`) too.

**Option B — on a Windows machine** with the [.NET 8 SDK](https://dotnet.microsoft.com/download):

```powershell
cd windows
pwsh ./build.ps1
# → publish/OcrReview.exe  (self-contained, no .NET install required to run)
```

## Feature parity

Open (⌘→Ctrl), per-page lazy OCR with next-page prefetch, split-pane review,
click-to-edit regions (bbox overlay), confidence heatmap (Ctrl+Alt+H), suspect spans +
spell suggestions, jump-to-issue (Alt+↑/↓), find & replace (Ctrl+F), command palette
(Ctrl+K), zoom (Ctrl +/−/0), page tools (rotate/reorder/append/combine/extract/delete),
basic redaction, recents, settings, and export to Markdown / Text / RTF / Word /
searchable PDF — plus debounced background autosave and cached thumbnails.

## Notes

- **OCR language:** Windows OCR needs a language pack — most installs include English.
  Add more in *Settings → Time & language → Language & region*.
- **Sidecar:** only needed for Word / searchable-PDF export and the Azure / PyMuPDF /
  LLM engines. The app auto-starts it from `~/markitdown-app` (override in Settings).
  Pure Windows-OCR review and Markdown/Text/RTF export work fully offline.
