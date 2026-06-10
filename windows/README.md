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

## Getting the app

CI produces two artifacts — pick **portable** unless you have a reason not to:

- **`OcrReview-win-x64-portable`** — a single `OcrReview.exe` with everything embedded.
  Copy it anywhere, double-click, done. No .NET install, no sibling DLLs to lose.
- **`OcrReview-win-x64`** — a self-contained folder (zipped). **Extract the zip fully**,
  then run `OcrReview.exe` from inside the folder (the sibling DLLs must stay next to it).

**Option A — GitHub Actions (no Windows machine needed).** Push the repo; the
[`Windows app`](../.github/workflows/windows-build.yml) workflow builds on a
`windows-latest` runner and uploads both artifacts. Trigger it
manually from the Actions tab (`workflow_dispatch`) too.

**Option B — on a Windows machine** with the [.NET 8 SDK](https://dotnet.microsoft.com/download):

```powershell
cd windows
pwsh ./build.ps1
# → publish\OcrReview.exe  (run it from the publish folder; self-contained)
```

## Troubleshooting "it won't open"

1. **Use the portable exe** (`OcrReview-win-x64-portable`) — it cannot suffer from
   missing files. For the folder artifact: don't run `OcrReview.exe` from inside the zip
   viewer — extract the whole folder, then launch it (the DLLs next to it are required).
2. **SmartScreen.** The build is unsigned, so Windows shows *"Windows protected your PC"* →
   click **More info → Run anyway**. (Right-click the .exe → Properties → **Unblock** also helps.)
3. **Antivirus** may quarantine a fresh unsigned .exe — check its quarantine/allow it.
4. **Crash log.** If the window never appears, the app writes the error to
   **`%LOCALAPPDATA%\OcrReview\crash.log`** — open it (or send it) to see the exact cause.
5. **Architecture.** This is an `x64` build; it runs on x64 and on Windows-on-ARM (via emulation).

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
