# OCR Review Robustness Hardening Plan

**Status:** Implemented and verified  
**Last updated:** June 10, 2026  
**Scope:** macOS OCR Review app, local Python sidecar integration, export/save/OCR reliability  
**Posture:** Local-only diagnostics. No telemetry. Preserve partial work over all-or-nothing behavior.

## Executive Summary

This hardening pass turns OCR Review from a workflow that could fail silently into one that records what happened, surfaces actionable errors, and keeps user work whenever possible.

The highest-risk workflow was multi-page OCR. Previously, an OCR failure late in a document could leave the user with a generic error and uncertain saved state. The app now saves successful pages as they complete, tracks failed pages individually, prevents duplicate OCR for the same page, supports cancellation, and exposes retry actions.

The app now also has a small reliability layer used by persistence, exports, sidecar startup, and OCR:

- `AppError`: user-safe title/message, technical context, recovery action.
- `OperationState`: idle/running/succeeded/failed with progress, page number, and cancel capability.
- `DiagnosticsLogger`: local rotating diagnostics logs under Application Support.
- Denoiser: repeated header/footer/page-number cleanup that applies as reversible text edits.

## What Was Built

### 1. Reliability Layer

Added `mac/OCRReview/Services/Reliability.swift`.

It provides:

- `AppError`: typed, user-safe errors with technical details for logs.
- `OperationState`: consistent operation state for long-running OCR/export work.
- `DiagnosticsLogger`: best-effort local rotating logs.

Diagnostics are written locally under:

```text
~/Library/Application Support/OCRReview/logs/diagnostics.log
```

Rotating logs keep recent local context without sending anything over the network.

### 2. Snapshot-Based Persistence

Reworked `JobStore` so saves are diagnosable and recoverable.

New behavior:

- Each document is saved as:
  - `current.json`
  - timestamped snapshot files in `snapshots/`
- If `current.json` is corrupt or missing, the app loads the newest valid snapshot.
- Recovery is surfaced inline as "Recovered from backup".
- Save failures are surfaced inline as "Save failed".
- Failed saves keep the latest document in memory and pending for retry.
- Snapshots are pruned to the last 20 or 100 MB per document, whichever limit is hit first.
- Legacy single-file job JSON loading is still supported and migrated forward.

This directly protects OCR/editor work during long sessions and app termination.

### 3. Export Hardening

Replaced silent export writes with explicit outcomes.

`ExportService` methods now return:

```swift
enum ExportOutcome {
    case saved(URL)
    case cancelled
    case failed(AppError)
}
```

New behavior:

- Save panel cancellation is handled as a normal `.cancelled`.
- Destination writability is checked before writing.
- Write failures return `.failed(AppError)` and appear in the inline notice banner.
- Export successes and failures are logged locally.
- PDF save operations now route through the same outcome path.

This covers Markdown, plain text, RTF, DOCX, searchable PDF, combined PDF, and extracted PDF saves.

### 4. Large Searchable PDF Upload Hardening

Searchable PDF export no longer builds the entire multipart request body in memory.

New behavior:

- The multipart body is streamed into a temporary file.
- `URLSession.upload(for:fromFile:)` uploads the temp file.
- The source PDF is read in chunks.
- The temporary multipart file is removed after the request.

This reduces memory pressure for large source PDFs.

### 5. Sidecar Lifecycle Diagnostics

Reworked `SidecarProcessManager` to make local sidecar failures actionable.

New behavior:

- Captures sidecar stdout and stderr into diagnostics logs.
- Keeps recent sidecar output for startup diagnosis.
- Maps startup failures to actionable messages:
  - missing project path
  - missing `uv`
  - port already in use
  - invalid project/API import
  - unhealthy API timeout
- Inline notice includes a Retry action.
- Settings still has Restart and Refresh actions.

`EngineSidecarClient.ensureAvailable()` now throws the sidecar manager's typed `AppError` when startup fails, so OCR/export callers get a useful message instead of a generic unreachable error.

### 6. OCR Workflow Hardening

Reworked the OCR path around partial success.

New behavior:

- `recognizeAllPages()` saves each successful page immediately.
- Failed pages are tracked in `failedPageNumbers`.
- Failed pages show a red status marker in the thumbnail strip.
- Failed current page shows a Retry Page action.
- `retryFailedPage(_:)` re-runs OCR for that page.
- `cancelCurrentOperation()` cancels long OCR/export operations.
- Completed OCR pages are preserved after cancellation.
- Duplicate concurrent OCR for the same page is blocked.
- Late async OCR results are ignored if the user has opened or closed another document.
- Conversion-only engines are blocked from page OCR.

This is the core fix for "it fails when multiple pages of a doc is OCR'd".

### 7. Inline UX Improvements

Replaced modal-only error handling with inline notices.

Inline notices now cover:

- OCR page failure
- partial OCR completion
- OCR cancellation
- export failure
- save failure
- backup recovery
- sidecar startup failure

The workspace now includes:

- OCR coverage HUD
- explicit export coverage text
- Denoise action for repeated headers, footers, and page numbers
- progress message with percentage
- cancel button when the operation is cancellable
- failed-page thumbnail marker
- retry action for failed OCR pages

### 8. Signal Denoiser

Added a document-level denoiser for OCR noise such as running headers, footers, and page numbers.

New behavior:

- Detects repeated edge text across OCR'd pages.
- Detects page-number patterns such as `1`, `- 1 -`, `Page 1`, `Page 1 of 50`, and `1/50`.
- Limits repeated-text detection to top/bottom page bands to avoid removing body content.
- Shows a confirmation dialog with removed-line count, affected pages, and candidate preview.
- Applies cleanup as editable page text, preserving original OCR for page-level Revert.
- Clears matching edge OCR blocks where possible so redacted/export block paths also avoid the noise.
- Logs denoiser actions locally.

Entry points:

- Workspace toolbar: **Denoise**
- Command palette: **Denoise Repeated Headers/Footers**
- Review menu: **Denoise Repeated Headers/Footers...**

## Important Files Changed

### New

- `mac/OCRReview/Services/Reliability.swift`

### Core macOS app

- `mac/OCRReview/Services/JobStore.swift`
- `mac/OCRReview/Services/ExportService.swift`
- `mac/OCRReview/Services/PDFToolsService.swift`
- `mac/OCRReview/Services/EngineSidecarClient.swift`
- `mac/OCRReview/Services/SidecarProcessManager.swift`
- `mac/OCRReview/ViewModels/DocumentViewModel.swift`
- `mac/OCRReview/Views/ContentView.swift`
- `mac/OCRReview/Views/ReviewWorkspaceView.swift`
- `mac/OCRReview/Views/PageThumbnailStrip.swift`
- `mac/OCRReview/Design/Components.swift`
- `mac/OCRReview/OCRReviewApp.swift`
- `mac/OCRReview.xcodeproj/project.pbxproj`

### Related existing hardening already present in this working tree

- API multipart/export validation and safer upload handling.
- Engine metadata exposes OCR capability.
- Converter-only engines are kept out of page OCR.
- Existing Python sidecar tests remain green.

## User-Facing Behavior After This Pass

### Multi-page OCR

If page 1 through page 30 succeed and page 31 fails:

- pages 1 through 30 are kept and saved
- page 31 is marked failed
- the user sees an inline error with recovery guidance
- the user can retry page 31
- exports include only OCR'd pages until the user completes OCR for the rest

### Denoising OCR Noise

If repeated headers, footers, or page numbers are present:

- the user clicks Denoise
- the app previews the number of noisy lines and candidate text
- the user confirms
- noisy edge lines are removed from editable text
- the original OCR remains available through Revert

### Cancellation

If the user cancels OCR halfway through a 50-page PDF:

- completed pages are kept
- pending pages remain unrecognized
- the app shows an inline cancellation notice
- reopening the app preserves completed OCR pages

### Save Failure

If saving fails:

- the latest document stays in memory
- the save error appears inline
- the error is logged locally
- the pending document remains queued for retry

### Corrupt `current.json`

If the current saved job is corrupt:

- the app searches snapshots newest-first
- the newest valid snapshot is loaded
- the user sees "Recovered from backup"
- the recovered document is written back as current

### Sidecar Startup Failure

If the sidecar cannot start:

- stdout/stderr are captured locally
- the app maps common causes to user-safe messages
- the inline notice includes Retry
- Settings still supports Restart/Refresh

## Verification Performed

### macOS build

```bash
xcodebuild -project mac/OCRReview.xcodeproj \
  -scheme OCRReview \
  -configuration Debug \
  -derivedDataPath mac/build \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Result:

```text
BUILD SUCCEEDED
```

Note: Xcode emitted local CoreSimulator/cache warnings in this environment, but the macOS target built successfully.

### Python sidecar tests

```bash
uv run pytest tests/ -q
```

Result:

```text
36 passed
```

## Manual Acceptance Checklist

Use this checklist for product QA:

- OCR a 50-page PDF, cancel mid-run, reopen the app, verify completed pages are preserved.
- OCR a multi-page PDF with a page that fails, verify successful pages remain and failed page can be retried.
- Corrupt a document `current.json`, reopen from recents, verify newest valid snapshot loads.
- Export to a blocked/unwritable destination, verify inline export failure appears.
- Start app while sidecar port is occupied, verify actionable sidecar message and Retry.
- Move or delete a recent source PDF, open recent, verify source failure is actionable.
- Select a conversion-only engine, verify it cannot be used for page OCR.
- OCR a document with repeated headers/footers/page numbers, run Denoise, verify only edge noise is removed.
- Revert a denoised page, verify original OCR text returns.

## Remaining Follow-Ups

The hardening foundation is now in place. Recommended next work:

1. Add a mac XCTest target for:
   - snapshot recovery
   - export write failure
   - sidecar startup failure mapping
   - converter-only engine OCR blocking
   - partial multi-page OCR preservation
2. Add a diagnostics viewer in Settings with "Reveal Logs in Finder".
3. Persist failed page numbers across launches if needed for long review sessions.
4. Add a small "Retry All Failed Pages" action.
5. Add a bounded queue for large all-page sidecar OCR with clearer ETA.
6. Add denoiser tuning controls for aggressive vs conservative cleanup if real-world samples need it.

## Design Principle Going Forward

OCR Review should never silently discard user work.

When something fails:

- keep every successful page
- keep the editor state
- save recoverable snapshots
- tell the user what happened
- give a concrete recovery action
- log technical context locally
