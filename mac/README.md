# OCR Review — macOS

Native **SwiftUI** app for Adobe-style OCR review on Mac.

## Requirements

- macOS 14+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Open in Xcode

```bash
cd ~/markitdown-app
make mac
```

Select the **OCRReview** scheme → **My Mac** → **Run** (⌘R).

## Build a signed Release app

Set your Apple Developer team ID (10-character string from developer.apple.com):

```bash
cd ~/markitdown-app
make mac-release DEVELOPMENT_TEAM=XXXXXXXXXX
```

Install to `/Applications`:

```bash
make mac-install DEVELOPMENT_TEAM=XXXXXXXXXX
```

Output: `mac/build/Build/Products/Release/OCR Review.app`

### Without a developer account

Open in Xcode, select the **OCRReview** target → **Signing & Capabilities** → enable **Sign to Run Locally**. For command-line builds, leave `DEVELOPMENT_TEAM` empty and sign in Xcode once.

## App icon

Icons live in `OCRReview/Assets.xcassets/AppIcon.appiconset/`. Source: `mac/design/app-icon-1024.png`.

Regenerate all sizes:

```bash
make mac-icons
```

## Features

- Open PDF/image (⌘O or drag & drop)
- Apple Vision OCR with bbox click-to-edit
- Jump-to-issue review (⌥↓ / ⌥↑), confidence heatmap (⌘⌥H)
- Find & replace (⌘F), revert to original OCR
- Export Markdown (⌘⇧E), Word (⌘⌥E), searchable PDF
- Page rotate / delete / reorder
- Auto-start Python sidecar for exports

## Python sidecar

The app auto-starts the sidecar from `~/markitdown-app` on launch. Manual start:

```bash
cd ~/markitdown-app
make api
```

Configure project path in **OCR Review → Settings**.
