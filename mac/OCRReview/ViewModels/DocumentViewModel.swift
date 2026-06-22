import AppKit
import PDFKit
import SwiftUI

@MainActor
final class DocumentViewModel: ObservableObject {
    @Published var document: OCRDocument?
    @Published var loadedSource: LoadedDocument?
    @Published var pdfDocument: PDFDocument?
    @Published var currentPageIndex: Int = 0
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var processingMessage = ""
    @Published var appError: AppError?
    @Published var errorMessage: String?
    @Published private(set) var operationState: OperationState = .idle
    @Published private(set) var failedPageNumbers: Set<Int> = []
    @Published private(set) var recognizingPageNumbers: Set<Int> = []
    @Published var pageJumpText = "1"
    @Published var isFindVisible = false
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var findMatches: [FindMatch] = []
    @Published var currentFindMatchIndex = 0
    @Published var selectedBlockID: UUID?
    @Published private(set) var pdfDocumentModified = false
    @Published var showConfidenceHeatmap = false
    @Published var isCommandPaletteVisible = false
    @Published var denoisePreview: DenoisePreviewState?
    @Published private(set) var canUndoDenoise = false

    private var denoiseUndoSnapshot: OCRDocument?

    let pdfController = PDFViewController()

    private let jobStore = JobStore.shared
    private var currentOperationTask: Task<Void, Never>?
    /// Bumped on every page delete/move/append. In-flight OCR results captured before
    /// the bump are dropped instead of merging at stale page numbers.
    private var pageStructureVersion = 0

    var totalPages: Int {
        if let pdfDocument { return pdfDocument.pageCount }
        return document?.totalPageCount ?? 1
    }

    var ocrPageCount: Int {
        document?.ocrPageCount ?? 0
    }

    var ocrCoverageFraction: Double {
        guard totalPages > 0 else { return 0 }
        return min(1, Double(ocrPageCount) / Double(totalPages))
    }

    var ocrCoverageLabel: String {
        "\(ocrPageCount)/\(totalPages) pages OCR'd"
    }

    var remainingOCRPageCount: Int {
        max(totalPages - ocrPageCount, 0)
    }

    var exportStatusLabel: String {
        if ocrPageCount == 0 {
            return "Run OCR before exporting Word or searchable PDF"
        }
        if remainingOCRPageCount > 0 {
            return "Exports include \(ocrPageCount) of \(totalPages) OCR'd pages"
        }
        return "Ready to export"
    }

    var engineLabel: String {
        OCRSettings.engineLabel(for: document?.engine ?? OCRSettings.selectedEngine)
    }

    var engineShortLabel: String {
        switch document?.engine ?? OCRSettings.selectedEngine {
        case "vision": return "Apple Vision"
        case "azure_doc_intel": return "Azure"
        case "pymupdf4llm": return "PyMuPDF4LLM"
        case "ocr_plugin": return "LLM OCR"
        case "builtin": return "Built-in"
        default: return "Engine"
        }
    }

    var engineIsLocal: Bool {
        (document?.engine ?? OCRSettings.selectedEngine) == "vision"
    }

    var currentOperationCanCancel: Bool {
        if case .running(_, _, _, let canCancel) = operationState {
            return canCancel
        }
        return false
    }

    var canDenoiseDocument: Bool {
        (document?.ocrPageCount ?? 0) > 0 && !isProcessing
    }

    /// Page numbers (1-based) that have been recognized.
    var ocrPageNumbers: Set<Int> {
        Set(document?.pages.map(\.pageNumber) ?? [])
    }

    /// Recognized pages that still have low-confidence regions.
    var issuePageNumbers: Set<Int> {
        guard let document else { return [] }
        return Set(document.pages.filter { !$0.lowConfidenceBlocks.isEmpty }.map(\.pageNumber))
    }

    /// Redacted block IDs on the current page (wired up by the redaction feature).
    var currentRedactedBlockIDs: Set<UUID> {
        Set((currentPage?.blocks ?? []).filter(\.isRedacted).map(\.id))
    }

    var currentPage: OCRPage? {
        document?.page(number: currentPageIndex + 1)
    }

    var currentPageHasOCR: Bool {
        currentPage != nil
    }

    var currentPageBinding: Binding<String> {
        Binding(
            get: {
                if let id = self.selectedBlockID,
                   let page = self.currentPage,
                   let block = page.blocks.first(where: { $0.id == id })
                {
                    return block.text
                }
                return self.currentPage?.displayText ?? ""
            },
            set: { newValue in
                if let id = self.selectedBlockID {
                    self.updateBlockText(id, text: newValue)
                } else {
                    self.updateCurrentPageText(newValue)
                }
            }
        )
    }

    var currentBlocks: [OCRBlock] {
        currentPage?.blocks.filter { $0.bboxNormalized != nil } ?? []
    }

    var editorModeLabel: String {
        if selectedBlockID != nil {
            return "Editing selected region"
        }
        return "Edit to fix OCR errors"
    }

    var currentPagePlaceholder: String {
        if currentPage != nil { return "" }
        return "No OCR for this page yet. Use Recognize This Page to extract editable text."
    }

    var lowConfidenceBlocks: [OCRBlock] {
        currentPage?.blocks.filter(\.isLowConfidence) ?? []
    }

    var issuesRemaining: Int {
        document?.issueCount ?? 0
    }

    /// Ordered low-confidence regions across recognized pages for review navigation.
    private var issueRefs: [(pageNumber: Int, blockID: UUID)] {
        guard let document else { return [] }
        var result: [(Int, UUID)] = []
        for page in document.pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            for block in page.issuesInReadingOrder {
                result.append((page.pageNumber, block.id))
            }
        }
        return result
    }

    var reviewSummary: String {
        guard let document, document.ocrPageCount > 0 else { return "" }
        let issues = document.issueCount
        if issues == 0 {
            return "All clear"
        }
        return "\(issues) to review"
    }

    var hasReviewIssues: Bool {
        (document?.issueCount ?? 0) > 0
    }

    var canRevertSelection: Bool {
        if let id = selectedBlockID {
            return currentPage?.blocks.first(where: { $0.id == id })?.hasEdits ?? false
        }
        return currentPage?.hasEdits ?? false
    }

    struct SpellIssueRef: Identifiable {
        let id: String
        let issue: SpellIssue
        let blockID: UUID

        init(issue: SpellIssue, blockID: UUID) {
            self.issue = issue
            self.blockID = blockID
            self.id = "\(blockID.uuidString)-\(issue.location)-\(issue.word)"
        }
    }

    var activeSpellIssueRefs: [SpellIssueRef] {
        let blocks: [OCRBlock]
        if let id = selectedBlockID, let block = currentPage?.blocks.first(where: { $0.id == id }) {
            blocks = [block]
        } else {
            blocks = lowConfidenceBlocks
        }
        return blocks.flatMap { block in
            SpellcheckService.issues(in: block.text).map { SpellIssueRef(issue: $0, blockID: block.id) }
        }
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.title = "Open Document"
        panel.allowedContentTypes = DocumentLoader.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url: url) }
    }

    /// Cancel in-flight work and clear per-document bookkeeping before loading a
    /// different document — otherwise stale tasks merge into the new document, stale
    /// page sets block its OCR, and a stale denoise plan can be applied to it.
    private func resetSessionState() {
        currentOperationTask?.cancel()
        currentOperationTask = nil
        pageStructureVersion += 1
        recognizingPageNumbers = []
        failedPageNumbers = []
        denoisePreview = nil
        denoiseUndoSnapshot = nil
        canUndoDenoise = false
        findMatches = []
        currentFindMatchIndex = 0
        selectedBlockID = nil
        ThumbnailCache.shared.clear()
    }

    func open(url: URL) async {
        clearError()
        resetSessionState()
        beginProcessing("Opening document…", progress: 0)
        defer { endProcessing() }

        do {
            let source = try DocumentLoader.load(from: url)
            loadedSource = source

            switch source {
            case .pdf(let ref):
                pdfDocument = DocumentLoader.pdfDocument(for: ref)
                document = OCRDocument(
                    filename: url.lastPathComponent,
                    sourcePath: url.path,
                    pages: [],
                    engine: OCRSettings.selectedEngine,
                    totalPageCount: ref.pageCount
                )
            case .image:
                pdfDocument = nil
                document = OCRDocument(
                    filename: url.lastPathComponent,
                    sourcePath: url.path,
                    pages: [],
                    engine: OCRSettings.selectedEngine,
                    totalPageCount: 1
                )
            }

            currentPageIndex = 0
            selectedBlockID = nil
            pdfDocumentModified = false
            syncPageJumpText()
            await recognizePage(at: currentPageIndex)
            if let document { jobStore.save(document) }
            prefetchAdjacent(around: currentPageIndex)
        } catch {
            presentError(
                AppError.wrap(
                    error,
                    kind: .open,
                    title: "Open failed",
                    fallback: "OCR Review could not open this document.",
                    recoveryAction: "Check that the file still exists and is a supported PDF or image."
                )
            )
            document = nil
            loadedSource = nil
            pdfDocument = nil
        }
    }

    func openRecent(_ recent: OCRDocument) {
        clearError()
        resetSessionState()
        do {
            let source = try DocumentLoader.load(from: recent.sourceURL)
            loadedSource = source
            switch source {
            case .pdf(let ref):
                pdfDocument = DocumentLoader.pdfDocument(for: ref)
            case .image:
                pdfDocument = nil
            }
            document = recent
            currentPageIndex = 0
            syncPageJumpText()
            // Recognize the first page if it isn't already, and prefetch the next —
            // otherwise a recent opened to an un-OCR'd page shows blank until you navigate.
            Task {
                await ensurePageRecognized(at: currentPageIndex)
                prefetchAdjacent(around: currentPageIndex)
            }
        } catch {
            presentError(
                AppError.wrap(
                    error,
                    kind: .open,
                    title: "Recent document unavailable",
                    fallback: "OCR Review could not reopen the source document.",
                    recoveryAction: "Restore the source file or open it from its new location."
                )
            )
        }
    }

    func goToPage(_ index: Int) {
        let clamped = min(max(index, 0), max(totalPages - 1, 0))
        currentPageIndex = clamped
        selectedBlockID = nil
        syncPageJumpText()
        Task {
            await ensurePageRecognized(at: clamped)
            prefetchAdjacent(around: clamped)
        }
    }

    /// Recognize the next page in the background so navigation feels instant.
    private func prefetchAdjacent(around index: Int) {
        guard OCRSettings.selectedEngine == "vision", loadedSource != nil else { return }
        let next = index + 1
        guard next < totalPages, document?.page(number: next + 1) == nil else { return }
        // Capture identity NOW: by the time Vision finishes, the user may have opened a
        // different document or restructured this one — merging then would corrupt it.
        guard let documentID = document?.id else { return }
        let structureVersion = pageStructureVersion
        Task { [weak self] in
            guard let self else { return }
            if let page = await self.visionPrefetch(index: next) {
                self.mergePrefetchedPage(page, documentID: documentID, structureVersion: structureVersion)
            }
        }
    }

    private func visionPrefetch(index: Int) async -> OCRPage? {
        switch loadedSource {
        case .pdf:
            guard let cgImage = renderSharedPageCGImage(at: index) else { return nil }
            return try? await VisionOCRService.recognize(cgImage: cgImage, pageNumber: index + 1)
        case .image(let url):
            return try? await VisionOCRService.recognize(imageURL: url, pageNumber: index + 1)
        case .none:
            return nil
        }
    }

    private func mergePrefetchedPage(_ page: OCRPage, documentID: UUID, structureVersion: Int) {
        guard var doc = document,
              doc.id == documentID,
              pageStructureVersion == structureVersion
        else { return }
        guard doc.page(number: page.pageNumber) == nil else { return }
        doc.pages.append(page)
        doc.pages.sort { $0.pageNumber < $1.pageNumber }
        document = doc
        jobStore.scheduleSave(doc)
    }

    /// Merge one recognized page into the document. `coalesceSave` batches the disk
    /// write (used when pages stream in rapidly from parallel OCR).
    private func mergeRecognizedPage(_ page: OCRPage, engine: String, coalesceSave: Bool = false) {
        guard var doc = document else { return }
        if let existing = doc.pages.firstIndex(where: { $0.pageNumber == page.pageNumber }) {
            doc.pages[existing] = page
        } else {
            doc.pages.append(page)
        }
        doc.pages.sort { $0.pageNumber < $1.pageNumber }
        doc.engine = engine
        document = doc
        if coalesceSave {
            jobStore.scheduleSave(doc)
        } else {
            jobStore.save(doc)
        }
        if page.pageNumber == currentPageIndex + 1 {
            selectedBlockID = nil
        }
        refreshFindResults()
    }

    private func validateOCRCapable(_ engine: String) throws {
        guard engine == "vision" || OCRSettings.supportsSidecarPageOCR(engine) else {
            throw AppError(
                kind: .validation,
                title: "Engine cannot OCR pages",
                userMessage: "\(OCRSettings.engineLabel(for: engine)) is a conversion-only engine and cannot OCR rendered page images.",
                recoveryAction: "Choose Apple Vision, Azure Document Intelligence, or LLM OCR in Settings."
            )
        }
    }

    private func startOperation(_ body: @escaping @MainActor () async -> Void) {
        guard currentOperationTask == nil else { return }
        currentOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.currentOperationTask = nil }
            await body()
        }
    }

    func jumpToPageFromField() {
        guard let number = Int(pageJumpText.trimmingCharacters(in: .whitespaces)), number >= 1 else { return }
        goToPage(number - 1)
    }

    func ensurePageRecognized(at index: Int) async {
        guard document != nil, currentPage(number: index + 1) == nil else { return }
        await recognizePage(at: index)
    }

    private func currentPage(number: Int) -> OCRPage? {
        document?.page(number: number)
    }

    func recognizeCurrentPage() {
        startOperation {
            await self.recognizePage(at: self.currentPageIndex)
        }
    }

    func recognizeAllPages() {
        guard currentOperationTask == nil else { return }
        currentOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.currentOperationTask = nil }
            let total = totalPages
            if total > 50 {
                let alert = NSAlert()
                alert.messageText = "Recognize all \(total) pages?"
                alert.informativeText = "Apple Vision recognizes pages in parallel on this Mac, but a document this large can still take a few minutes. You can keep reviewing pages while it runs and cancel at any time."
                alert.addButton(withTitle: "Recognize All")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            await recognizeAllPagesAsync()
        }
    }

    func cancelCurrentOperation() {
        currentOperationTask?.cancel()
        DiagnosticsLogger.shared.log(level: .info, event: "operation.cancel_requested")
    }

    func retryFailedPage(_ pageNumber: Int) {
        let index = pageNumber - 1
        guard index >= 0, index < totalPages else { return }
        currentPageIndex = index
        syncPageJumpText()
        startOperation {
            await self.recognizePage(at: index, force: true)
        }
    }

    /// Render a page of the shared on-screen document to an image **on the main actor**.
    /// PDFKit is not thread-safe and this document is shared with the PDF view, so its
    /// pages must never be rendered on a background thread.
    private func renderSharedPageCGImage(at index: Int, scale: CGFloat = 2.0) -> CGImage? {
        guard let page = pdfDocument?.page(at: index) else { return nil }
        return VisionOCRService.renderPage(page, scale: scale)
    }

    /// Recognize one page using the in-memory document (no disk re-parse).
    private func recognizeSinglePage(at index: Int, engine: String) async throws -> OCRPage {
        try validateOCRCapable(engine)
        try Task.checkCancellation()
        guard let source = loadedSource else { throw OCRError.openFailed }
        switch source {
        case .pdf:
            guard let cgImage = renderSharedPageCGImage(at: index) else { throw OCRError.renderFailed }
            if engine == "vision" {
                return try await VisionOCRService.recognize(cgImage: cgImage, pageNumber: index + 1)
            }
            try await EngineSidecarClient.ensureAvailable()
            return try await SidecarOCRService.recognize(cgImage: cgImage, pageNumber: index + 1, engine: engine)
        case .image(let url):
            if engine == "vision" {
                return try await VisionOCRService.recognize(imageURL: url, pageNumber: index + 1)
            }
            try await EngineSidecarClient.ensureAvailable()
            return try await SidecarOCRService.recognize(imageURL: url, pageNumber: index + 1, engine: engine)
        }
    }

    private func recognizePage(at index: Int, force: Bool = false) async {
        guard let startingDocumentID = document?.id, loadedSource != nil else { return }
        let pageNumber = index + 1
        if !force, currentPage(number: pageNumber) != nil, !failedPageNumbers.contains(pageNumber) { return }
        guard !recognizingPageNumbers.contains(pageNumber) else { return }
        let structureVersion = pageStructureVersion

        recognizingPageNumbers.insert(pageNumber)
        failedPageNumbers.remove(pageNumber)
        beginProcessing("Recognizing page \(pageNumber)…", progress: 0, pageNumber: pageNumber, canCancel: currentOperationTask != nil)
        defer {
            // Only clean up our own document's bookkeeping — if the user switched
            // documents mid-flight, these sets and the processing state belong to the
            // NEW document's operations now.
            if document?.id == startingDocumentID {
                recognizingPageNumbers.remove(pageNumber)
                endProcessing()
            }
        }

        do {
            let engine = OCRSettings.selectedEngine
            let page = try await recognizeSinglePage(at: index, engine: engine)
            try Task.checkCancellation()
            guard document?.id == startingDocumentID, pageStructureVersion == structureVersion else { return }
            mergeRecognizedPage(page, engine: engine)
            progress = 1
            failedPageNumbers.remove(pageNumber)
            DiagnosticsLogger.shared.log(
                level: .info,
                event: "ocr.page_succeeded",
                context: ["page": "\(pageNumber)", "engine": engine]
            )
        } catch is CancellationError {
            presentWarning("OCR cancelled. Completed pages were kept.")
        } catch {
            failedPageNumbers.insert(pageNumber)
            let appError = AppError.wrap(
                error,
                kind: .ocr,
                title: "OCR failed on page \(pageNumber)",
                fallback: "OCR Review could not recognize page \(pageNumber).",
                recoveryAction: "Use Retry Failed Page after checking the sidecar or source file."
            )
            presentError(appError)
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "ocr.page_failed",
                context: ["page": "\(pageNumber)", "error": String(describing: error)]
            )
        }
    }

    private func recognizeAllPagesAsync() async {
        guard let startingDocumentID = document?.id, loadedSource != nil else { return }
        let structureVersion = pageStructureVersion
        beginProcessing("Recognizing all pages…", progress: 0, canCancel: true)
        defer {
            progress = 1
            endProcessing()
        }

        do {
            let engine = OCRSettings.selectedEngine
            try validateOCRCapable(engine)
            if engine != "vision" {
                try await EngineSidecarClient.ensureAvailable()
            }

            var successCount = 0
            var failures: [String] = []
            let total = totalPages

            // Fast path: Apple Vision on a PDF recognizes pages in parallel. Each worker
            // opens its own PDFDocument from disk, so the shared on-screen document is
            // never touched off the main thread.
            if engine == "vision", case .pdf = loadedSource {
                try await recognizeAllPagesParallel(engine: engine)
                return
            }

            for index in 0..<total {
                try Task.checkCancellation()
                let pageNumber = index + 1
                if currentPage(number: pageNumber) != nil, !failedPageNumbers.contains(pageNumber) {
                    progress = Double(index + 1) / Double(max(total, 1))
                    continue
                }
                if recognizingPageNumbers.contains(pageNumber) {
                    progress = Double(index + 1) / Double(max(total, 1))
                    continue
                }

                recognizingPageNumbers.insert(pageNumber)
                failedPageNumbers.remove(pageNumber)
                defer { recognizingPageNumbers.remove(pageNumber) }

                processingMessage = "Recognizing page \(pageNumber) of \(total)…"
                operationState = .running(
                    message: processingMessage,
                    progress: progress,
                    pageNumber: pageNumber,
                    canCancel: true
                )
                do {
                    let page = try await recognizeSinglePage(at: index, engine: engine)
                    try Task.checkCancellation()
                    guard document?.id == startingDocumentID, pageStructureVersion == structureVersion else {
                        throw CancellationError()
                    }
                    mergeRecognizedPage(page, engine: engine)
                    successCount += 1
                    failedPageNumbers.remove(pageNumber)
                    DiagnosticsLogger.shared.log(
                        level: .info,
                        event: "ocr.page_succeeded",
                        context: ["page": "\(pageNumber)", "engine": engine]
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append("Page \(pageNumber): \(error.localizedDescription)")
                    failedPageNumbers.insert(pageNumber)
                    DiagnosticsLogger.shared.log(
                        level: .error,
                        event: "ocr.page_failed",
                        context: ["page": "\(pageNumber)", "error": String(describing: error)]
                    )
                }
                progress = Double(index + 1) / Double(max(total, 1))
            }

            if successCount == 0, !failures.isEmpty {
                let firstFailure = failures.first.map { " \($0)" } ?? ""
                throw SidecarError.serverError("OCR failed for all \(total) pages.\(firstFailure)")
            }
            if !failures.isEmpty {
                let preview = failures.prefix(3).joined(separator: "\n")
                let remaining = failures.count > 3 ? "\n…and \(failures.count - 3) more." : ""
                presentWarning("OCR completed for \(successCount) page\(successCount == 1 ? "" : "s").\n\(preview)\(remaining)")
            }
        } catch is CancellationError {
            presentWarning("OCR cancelled. Completed pages were kept.")
        } catch {
            presentError(
                AppError.wrap(
                    error,
                    kind: .ocr,
                    title: "OCR failed",
                    fallback: "OCR Review could not finish recognizing the document.",
                    recoveryAction: "Retry failed pages or check the sidecar status in Settings."
                )
            )
        }
    }

    /// Vision-on-PDF fast path: recognize all missing pages in parallel. Pages stream in
    /// as they finish, so cancellation keeps completed work and the UI updates live.
    private func recognizeAllPagesParallel(engine: String) async throws {
        guard let startingDocumentID = document?.id else { return }
        let structureVersion = pageStructureVersion
        let missing = (0..<totalPages).filter { index in
            let pageNumber = index + 1
            guard !recognizingPageNumbers.contains(pageNumber) else { return false }
            return currentPage(number: pageNumber) == nil || failedPageNumbers.contains(pageNumber)
        }
        guard !missing.isEmpty else { return }

        let url = try resolvedSourceURL()
        let missingNumbers = Set(missing.map { $0 + 1 })
        recognizingPageNumbers.formUnion(missingNumbers)
        failedPageNumbers.subtract(missingNumbers)
        defer {
            recognizingPageNumbers.subtract(missingNumbers)
            jobStore.flush()
        }

        processingMessage = "Recognizing \(missing.count) page\(missing.count == 1 ? "" : "s")…"
        operationState = .running(message: processingMessage, progress: 0, pageNumber: nil, canCancel: true)

        let result = try await VisionOCRService.recognizePages(
            pdfURL: url,
            pageIndexes: missing,
            onPage: { page in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.document?.id == startingDocumentID,
                          self.pageStructureVersion == structureVersion
                    else { return }
                    self.mergeRecognizedPage(page, engine: engine, coalesceSave: true)
                    self.failedPageNumbers.remove(page.pageNumber)
                    self.recognizingPageNumbers.remove(page.pageNumber)
                }
            },
            onProgress: { fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.isProcessing else { return }
                    self.progress = fraction
                    self.operationState = .running(
                        message: self.processingMessage,
                        progress: fraction,
                        pageNumber: nil,
                        canCancel: true
                    )
                }
            }
        )

        guard document?.id == startingDocumentID else { return }
        for failure in result.failures {
            failedPageNumbers.insert(failure.pageNumber)
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "ocr.page_failed",
                context: ["page": "\(failure.pageNumber)", "error": failure.message]
            )
        }
        if result.succeededCount == 0, !result.failures.isEmpty {
            let first = result.failures.first.map { " Page \($0.pageNumber): \($0.message)" } ?? ""
            throw SidecarError.serverError("OCR failed for all \(missing.count) pages.\(first)")
        }
        if !result.failures.isEmpty {
            let preview = result.failures.prefix(3)
                .map { "Page \($0.pageNumber): \($0.message)" }
                .joined(separator: "\n")
            let remaining = result.failures.count > 3 ? "\n…and \(result.failures.count - 3) more." : ""
            presentWarning("OCR completed for \(result.succeededCount) page\(result.succeededCount == 1 ? "" : "s").\n\(preview)\(remaining)")
        }
        DiagnosticsLogger.shared.log(
            level: .info,
            event: "ocr.parallel_completed",
            context: ["pages": "\(result.succeededCount)", "failed": "\(result.failures.count)"]
        )
    }

    func updateCurrentPageText(_ text: String) {
        guard var doc = document else { return }
        selectedBlockID = nil
        let pageNumber = currentPageIndex + 1
        if let index = doc.pages.firstIndex(where: { $0.pageNumber == pageNumber }) {
            doc.pages[index].setDisplayText(text)
        } else {
            doc.pages.append(OCRPage(pageNumber: pageNumber, ocrText: "", editedText: text))
            doc.pages.sort { $0.pageNumber < $1.pageNumber }
        }
        document = doc
        jobStore.scheduleSave(doc)
    }

    func selectBlock(_ id: UUID?) {
        selectedBlockID = id
    }

    // MARK: - Redaction

    var isSelectedRegionRedacted: Bool {
        guard let id = selectedBlockID else { return false }
        return currentPage?.blocks.first(where: { $0.id == id })?.isRedacted ?? false
    }

    func toggleRedactionForSelection() {
        guard var doc = document, let id = selectedBlockID else { return }
        let pageNumber = currentPageIndex + 1
        guard let pageIndex = doc.pages.firstIndex(where: { $0.pageNumber == pageNumber }),
              let blockIndex = doc.pages[pageIndex].blocks.firstIndex(where: { $0.id == id })
        else { return }

        doc.pages[pageIndex].blocks[blockIndex].isRedacted.toggle()
        document = doc
        jobStore.scheduleSave(doc)
        refreshFindResults()
    }

    func selectBlockFromSuspect(_ block: OCRBlock) {
        selectedBlockID = block.id
    }

    func goToNextIssue() {
        let refs = issueRefs
        guard !refs.isEmpty else { return }
        let currentPageNumber = currentPageIndex + 1
        let startIndex: Int
        if let idx = refs.firstIndex(where: { $0.pageNumber == currentPageNumber && $0.blockID == selectedBlockID }) {
            startIndex = (idx + 1) % refs.count
        } else if let idx = refs.firstIndex(where: { $0.pageNumber >= currentPageNumber }) {
            startIndex = idx
        } else {
            startIndex = 0
        }
        focusIssue(refs[startIndex])
    }

    func goToPreviousIssue() {
        let refs = issueRefs
        guard !refs.isEmpty else { return }
        let currentPageNumber = currentPageIndex + 1
        let startIndex: Int
        if let idx = refs.firstIndex(where: { $0.pageNumber == currentPageNumber && $0.blockID == selectedBlockID }) {
            startIndex = (idx - 1 + refs.count) % refs.count
        } else if let idx = refs.lastIndex(where: { $0.pageNumber <= currentPageNumber }) {
            startIndex = idx
        } else {
            startIndex = refs.count - 1
        }
        focusIssue(refs[startIndex])
    }

    private func focusIssue(_ ref: (pageNumber: Int, blockID: UUID)) {
        currentPageIndex = min(max(ref.pageNumber - 1, 0), max(totalPages - 1, 0))
        syncPageJumpText()
        selectedBlockID = ref.blockID
    }

    func revertSelection() {
        guard var doc = document else { return }
        let pageNumber = currentPageIndex + 1
        guard let pageIndex = doc.pages.firstIndex(where: { $0.pageNumber == pageNumber }) else { return }

        if let id = selectedBlockID,
           let blockIndex = doc.pages[pageIndex].blocks.firstIndex(where: { $0.id == id })
        {
            doc.pages[pageIndex].blocks[blockIndex].revertToOriginal()
            doc.pages[pageIndex].syncEditedTextFromBlocks()
        } else {
            doc.pages[pageIndex].revertToOriginal()
        }
        document = doc
        jobStore.scheduleSave(doc)
        refreshFindResults()
    }

    func revertCurrentPage() {
        guard var doc = document else { return }
        let pageNumber = currentPageIndex + 1
        guard let pageIndex = doc.pages.firstIndex(where: { $0.pageNumber == pageNumber }),
              doc.pages[pageIndex].hasEdits
        else { return }

        let alert = NSAlert()
        alert.messageText = "Revert page \(pageNumber) to original OCR?"
        alert.informativeText = "Your edits on this page will be discarded."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        doc.pages[pageIndex].revertToOriginal()
        document = doc
        jobStore.save(doc)
        selectedBlockID = nil
        refreshFindResults()
    }

    func applySpellFix(_ ref: SpellIssueRef, replacement: String) {
        guard var doc = document else { return }
        let pageNumber = currentPageIndex + 1
        guard let pageIndex = doc.pages.firstIndex(where: { $0.pageNumber == pageNumber }) else { return }
        guard let blockIndex = doc.pages[pageIndex].blocks.firstIndex(where: { $0.id == ref.blockID }) else { return }

        let blockText = doc.pages[pageIndex].blocks[blockIndex].text
        let updated = SpellcheckService.replace(in: blockText, issue: ref.issue, with: replacement)
        doc.pages[pageIndex].blocks[blockIndex].text = updated
        doc.pages[pageIndex].syncEditedTextFromBlocks()
        document = doc
        selectedBlockID = ref.blockID
        jobStore.scheduleSave(doc)
        refreshFindResults()
    }

    struct DenoisePreviewState: Identifiable {
        let id = UUID()
        let plan: DenoiseService.Plan
        var enabledKeys: Set<String>
    }

    func denoiseDocument() {
        guard let document else { return }
        guard document.ocrPageCount > 0 else {
            presentError(
                AppError(
                    kind: .validation,
                    title: "No OCR text to denoise",
                    userMessage: "Run OCR on at least one page before denoising."
                )
            )
            return
        }

        let plan = DenoiseService.makePlan(for: document)
        guard plan.removedLineCount > 0 else {
            presentWarning("Denoise found no repeated headers, footers, or page numbers in OCR'd pages.")
            DiagnosticsLogger.shared.log(level: .info, event: "denoise.noop", context: ["document": document.id.uuidString])
            return
        }

        denoisePreview = DenoisePreviewState(plan: plan, enabledKeys: plan.allCandidateKeys)
    }

    func cancelDenoisePreview() {
        denoisePreview = nil
        if let document {
            DiagnosticsLogger.shared.log(level: .info, event: "denoise.cancelled", context: ["document": document.id.uuidString])
        }
    }

    func applyDenoisePreview() {
        guard let preview = denoisePreview, let document else { return }
        denoisePreview = nil

        let result = DenoiseService.apply(plan: preview.plan, to: document, enabledKeys: preview.enabledKeys)
        let plan = result.plan
        guard plan.removedLineCount > 0 else { return }

        denoiseUndoSnapshot = document
        canUndoDenoise = true
        self.document = result.document
        selectedBlockID = nil
        jobStore.save(result.document)
        refreshFindResults()
        presentWarning("Denoise removed \(plan.removedLineCount) noisy line\(plan.removedLineCount == 1 ? "" : "s") across \(plan.affectedPageCount) page\(plan.affectedPageCount == 1 ? "" : "s").")
        DiagnosticsLogger.shared.log(
            level: .info,
            event: "denoise.applied",
            context: [
                "document": document.id.uuidString,
                "removedLines": "\(plan.removedLineCount)",
                "affectedPages": "\(plan.affectedPageCount)",
            ]
        )
    }

    func undoDenoise() {
        // The snapshot is only valid for the document it was taken from (a new document
        // can be drag-opened while the undo banner is still visible).
        guard let snapshot = denoiseUndoSnapshot, snapshot.id == document?.id else {
            denoiseUndoSnapshot = nil
            canUndoDenoise = false
            return
        }
        denoiseUndoSnapshot = nil
        canUndoDenoise = false
        document = snapshot
        selectedBlockID = nil
        jobStore.save(snapshot)
        refreshFindResults()
        presentWarning("Denoise undone — original OCR text restored.")
        DiagnosticsLogger.shared.log(level: .info, event: "denoise.undone", context: ["document": snapshot.id.uuidString])
    }

    func appendPDFs() {
        if blockStructureEditIfProcessing() { return }
        guard let pdf = pdfDocument else {
            presentError(
                AppError(
                    kind: .validation,
                    title: "No PDF open",
                    userMessage: "Open a PDF before appending other files."
                )
            )
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Append PDFs"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let added = PDFToolsService.appendPDFs(from: panel.urls, to: pdf)
        pageStructureVersion += 1
        guard added > 0 else {
            presentError(
                AppError(
                    kind: .open,
                    title: "Append failed",
                    userMessage: "OCR Review could not append any pages from the selected PDFs.",
                    recoveryAction: "Check that the selected files are valid PDFs."
                )
            )
            return
        }

        pdfDocumentModified = true
        pdfDocument = pdf
        if var doc = document {
            doc.totalPageCount = pdf.pageCount
            document = doc
            jobStore.save(doc)
        }
    }

    func combinePDFs() {
        let panel = NSOpenPanel()
        panel.title = "Combine PDFs"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, panel.urls.count >= 2 else { return }

        guard let combined = PDFToolsService.combine(urls: panel.urls) else {
            presentError(
                AppError(
                    kind: .open,
                    title: "Combine failed",
                    userMessage: "OCR Review could not combine the selected PDFs.",
                    recoveryAction: "Check that the selected files are valid PDFs."
                )
            )
            return
        }

        switch PDFToolsService.savePDFOutcome(combined, suggestedFilename: "combined.pdf", from: NSApp.keyWindow) {
        case .saved(let savedURL):
            Task { await open(url: savedURL) }
        case .cancelled:
            break
        case .failed(let error):
            presentError(error)
        }
    }

    func splitPDFPrompt() {
        guard pdfDocument != nil else {
            presentError(
                AppError(
                    kind: .validation,
                    title: "No PDF open",
                    userMessage: "Open a PDF before splitting."
                )
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Extract pages to new PDF"
        alert.informativeText = "Enter a page range (e.g. 3-10 or 5). The original document stays unchanged."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = "\(currentPageIndex + 1)-\(currentPageIndex + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        splitPDF(pageRangeText: input.stringValue)
    }

    func splitPDF(pageRangeText: String) {
        guard let pdf = pdfDocument else { return }
        guard let range = PDFToolsService.parsePageRange(pageRangeText, totalPages: totalPages) else {
            presentError(
                AppError(
                    kind: .validation,
                    title: "Invalid page range",
                    userMessage: "Use a valid page range such as 3-10 or 5."
                )
            )
            return
        }
        guard let extracted = PDFToolsService.extractPages(from: pdf, range: range) else {
            presentError(
                AppError(
                    kind: .export,
                    title: "Extract failed",
                    userMessage: "OCR Review could not extract those pages.",
                    recoveryAction: "Check the page range and try again."
                )
            )
            return
        }

        let filename = "pages_\(range.lowerBound)-\(range.upperBound).pdf"
        handleExportOutcome(PDFToolsService.savePDFOutcome(extracted, suggestedFilename: filename, from: NSApp.keyWindow))
    }

    func updateBlockText(_ blockID: UUID, text: String) {
        guard var doc = document else { return }
        let pageNumber = currentPageIndex + 1
        guard let pageIndex = doc.pages.firstIndex(where: { $0.pageNumber == pageNumber }) else { return }
        guard let blockIndex = doc.pages[pageIndex].blocks.firstIndex(where: { $0.id == blockID }) else { return }

        doc.pages[pageIndex].blocks[blockIndex].text = text
        doc.pages[pageIndex].syncEditedTextFromBlocks()
        document = doc
        jobStore.scheduleSave(doc)
        refreshFindResults()
    }

    func rotateCurrentPage(clockwise: Bool = true) {
        guard let pdf = pdfDocument, let page = pdf.page(at: currentPageIndex) else { return }
        let delta: Int = clockwise ? 90 : -90
        page.rotation = (page.rotation + delta) % 360
        if page.rotation < 0 { page.rotation += 360 }
        pdfDocumentModified = true
        pdfDocument = pdf
    }

    func rotatePage(at index: Int, clockwise: Bool = true) {
        goToPage(index)
        rotateCurrentPage(clockwise: clockwise)
    }

    func deleteCurrentPage() {
        deletePage(at: currentPageIndex)
    }

    /// Structure edits are blocked while OCR is in flight: workers stream results keyed
    /// by page number, and renumbering pages underneath them corrupts the mapping.
    private func blockStructureEditIfProcessing() -> Bool {
        guard isProcessing else { return false }
        presentWarning("Finish or cancel the current operation before changing pages.")
        return true
    }

    func deletePage(at index: Int) {
        if blockStructureEditIfProcessing() { return }
        guard let pdf = pdfDocument, pdf.pageCount > 1, index >= 0, index < pdf.pageCount else {
            presentError(
                AppError(
                    kind: .validation,
                    title: "Cannot delete page",
                    userMessage: "OCR Review cannot delete the only page in the document."
                )
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete page \(index + 1)?"
        alert.informativeText = "OCR text for this page will also be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        pdf.removePage(at: index)
        pdfDocumentModified = true
        pdfDocument = pdf
        pageStructureVersion += 1

        if var doc = document {
            doc.pages = PageStructureService.remapAfterDelete(
                pages: doc.pages,
                deletedPageNumber: index + 1
            )
            doc.totalPageCount = pdf.pageCount
            document = doc
            jobStore.save(doc)
        }

        // Keep the failure badges pointing at the same physical pages.
        let deletedNumber = index + 1
        failedPageNumbers = Set(failedPageNumbers.compactMap { n in
            if n == deletedNumber { return nil }
            return n > deletedNumber ? n - 1 : n
        })

        if currentPageIndex >= pdf.pageCount {
            currentPageIndex = max(0, pdf.pageCount - 1)
        } else if index < currentPageIndex {
            currentPageIndex -= 1
        }
        selectedBlockID = nil
        syncPageJumpText()
    }

    func movePage(from sourceIndex: Int, to destIndex: Int) {
        if blockStructureEditIfProcessing() { return }
        guard let pdf = pdfDocument, var doc = document else { return }
        guard sourceIndex != destIndex,
              sourceIndex >= 0, destIndex >= 0,
              sourceIndex < pdf.pageCount, destIndex < pdf.pageCount,
              let page = pdf.page(at: sourceIndex)
        else { return }

        pdf.removePage(at: sourceIndex)
        pdf.insert(page, at: destIndex)
        pdfDocumentModified = true
        pdfDocument = pdf
        pageStructureVersion += 1
        // Failure badges can't be remapped cheaply across a move; recompute on retry.
        failedPageNumbers = []

        doc.pages = PageStructureService.remapAfterMove(
            pages: doc.pages,
            fromIndex: sourceIndex,
            toIndex: destIndex,
            pageCount: pdf.pageCount
        )
        doc.totalPageCount = pdf.pageCount
        document = doc
        jobStore.save(doc)

        if currentPageIndex == sourceIndex {
            currentPageIndex = destIndex
        } else if sourceIndex < currentPageIndex && destIndex >= currentPageIndex {
            currentPageIndex -= 1
        } else if sourceIndex > currentPageIndex && destIndex <= currentPageIndex {
            currentPageIndex += 1
        }
        selectedBlockID = nil
        syncPageJumpText()
    }

    private func resolvedSourceURL() throws -> URL {
        guard let source = loadedSource else { throw OCRError.openFailed }
        if pdfDocumentModified, let pdf = pdfDocument {
            let name = document?.filename ?? "export.pdf"
            return try DocumentLoader.writeTempPDF(pdf, filename: name)
        }
        switch source {
        case .pdf(let ref):
            return ref.url
        case .image(let url):
            return url
        }
    }

    func exportMarkdown() {
        guard let document else { return }
        let stem = document.filename
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".jpg", with: "", options: .caseInsensitive)

        startOperation {
            self.beginProcessing("Exporting Markdown…", progress: 0, canCancel: true)
            self.clearError()
            defer { self.endProcessing() }

            // Prefer the sidecar's layout-aware Markdown (headings, lists, tables);
            // fall back to the local line dump when the sidecar is unavailable.
            var text: String?
            if document.ocrPageCount > 0 {
                do {
                    try await EngineSidecarClient.ensureAvailable()
                    text = try await EngineSidecarClient.exportMarkdown(document: document)
                } catch is CancellationError {
                    self.presentWarning("Export cancelled.")
                    return
                } catch {
                    text = nil  // fall back to local generation below
                }
            }
            let markdownText = text ?? ExportService.markdown(for: document, totalPages: self.totalPages)
            self.progress = 0.8
            self.handleExportOutcome(
                ExportService.saveMarkdown(
                    markdownText,
                    suggestedFilename: "\(stem).md",
                    from: NSApp.keyWindow
                )
            )
        }
    }

    func exportDOCX() {
        guard let document else { return }
        startOperation {
            self.beginProcessing("Exporting Word document…", progress: 0, canCancel: true)
            self.clearError()
            defer { self.endProcessing() }

            do {
                try await EngineSidecarClient.ensureAvailable()
                let docxData = try await EngineSidecarClient.exportDOCX(document: document)
                self.progress = 0.8
                let stem = document.filename
                    .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".jpg", with: "", options: .caseInsensitive)
                self.handleExportOutcome(
                    ExportService.exportDOCX(
                        data: docxData,
                        suggestedFilename: "\(stem).docx",
                        from: NSApp.keyWindow
                    )
                )
            } catch is CancellationError {
                self.presentWarning("Export cancelled.")
            } catch {
                self.presentError(
                    AppError.wrap(
                        error,
                        kind: .export,
                        title: "Export failed",
                        fallback: "OCR Review could not export the Word document.",
                        recoveryAction: "Check the sidecar status and try again."
                    )
                )
            }
        }
    }

    func exportSearchablePDF() {
        guard let document else { return }

        startOperation {
            self.beginProcessing("Building searchable PDF…", progress: 0, canCancel: true)
            self.clearError()
            defer { self.endProcessing() }

            do {
                // Resolve the source BEFORE any await: a slow sidecar health check must
                // not let a newly opened document swap in under this export.
                let sourceURL = try self.resolvedSourceURL()
                try await EngineSidecarClient.ensureAvailable()
                let pdfData = try await EngineSidecarClient.exportSearchablePDF(
                    sourceURL: sourceURL,
                    document: document
                )
                self.progress = 0.8
                let stem = document.filename
                    .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".jpg", with: "", options: .caseInsensitive)
                self.handleExportOutcome(
                    ExportService.exportSearchablePDF(
                        data: pdfData,
                        suggestedFilename: "\(stem)_searchable.pdf",
                        from: NSApp.keyWindow
                    )
                )
            } catch is CancellationError {
                self.presentWarning("Export cancelled.")
            } catch {
                self.presentError(
                    AppError.wrap(
                        error,
                        kind: .export,
                        title: "Export failed",
                        fallback: "OCR Review could not build the searchable PDF.",
                        recoveryAction: "Check that the source PDF still exists and the sidecar is running."
                    )
                )
            }
        }
    }

    private func filenameStem() -> String {
        (document?.filename ?? "document")
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".jpg", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".jpeg", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".tiff", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".tif", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".heic", with: "", options: .caseInsensitive)
    }

    func exportText() {
        guard let document else { return }
        handleExportOutcome(
            ExportService.exportPlainText(
                document: document,
                totalPages: totalPages,
                suggestedFilename: "\(filenameStem()).txt",
                from: NSApp.keyWindow
            )
        )
    }

    func exportRTF() {
        guard let document else { return }
        handleExportOutcome(
            ExportService.exportRTF(
                document: document,
                totalPages: totalPages,
                suggestedFilename: "\(filenameStem()).rtf",
                from: NSApp.keyWindow
            )
        )
    }

    func copyCurrentPageText() {
        setClipboard(currentPage?.exportText ?? "")
    }

    func copyAllText() {
        guard let document else { return }
        setClipboard(ExportService.plainText(for: document, totalPages: totalPages))
    }

    private func setClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func closeDocument() {
        currentOperationTask?.cancel()
        currentOperationTask = nil
        jobStore.flush()
        document = nil
        loadedSource = nil
        pdfDocument = nil
        currentPageIndex = 0
        isFindVisible = false
        findText = ""
        replaceText = ""
        findMatches = []
        currentFindMatchIndex = 0
        selectedBlockID = nil
        pdfDocumentModified = false
        processingMessage = ""
        appError = nil
        errorMessage = nil
        operationState = .idle
        failedPageNumbers = []
        recognizingPageNumbers = []
        denoisePreview = nil
        denoiseUndoSnapshot = nil
        canUndoDenoise = false
        pageStructureVersion += 1
        ThumbnailCache.shared.clear()
    }

    func clearError() {
        appError = nil
        errorMessage = nil
    }

    private func presentError(_ error: AppError) {
        appError = error
        errorMessage = error.displayMessage
        operationState = .failed(error)
        DiagnosticsLogger.shared.log(
            level: .error,
            event: "app.error",
            context: [
                "kind": error.kind.rawValue,
                "title": error.title,
                "message": error.userMessage,
                "technical": error.technicalMessage ?? "",
            ]
        )
    }

    private func presentWarning(_ message: String) {
        appError = nil
        errorMessage = message
        DiagnosticsLogger.shared.log(level: .warning, event: "app.warning", context: ["message": message])
    }

    private func handleExportOutcome(_ outcome: ExportOutcome) {
        switch outcome {
        case .saved(let url):
            clearError()
            DiagnosticsLogger.shared.log(level: .info, event: "export.completed", context: ["url": url.path])
        case .cancelled:
            DiagnosticsLogger.shared.log(level: .info, event: "export.cancelled")
        case .failed(let error):
            presentError(error)
        }
    }

    private func beginProcessing(_ message: String, progress: Double = 0, pageNumber: Int? = nil, canCancel: Bool = false) {
        processingMessage = message
        self.progress = progress
        isProcessing = true
        operationState = .running(
            message: message,
            progress: progress,
            pageNumber: pageNumber,
            canCancel: canCancel
        )
    }

    private func endProcessing() {
        isProcessing = false
        processingMessage = ""
        if operationState.isRunning {
            operationState = .idle
        }
    }

    func toggleFindPanel() {
        isFindVisible.toggle()
        if isFindVisible {
            refreshFindResults()
        }
    }

    func refreshFindResults() {
        guard let document else {
            findMatches = []
            currentFindMatchIndex = 0
            return
        }
        findMatches = FindService.find(in: document, query: findText)
        if findMatches.isEmpty {
            currentFindMatchIndex = 0
        } else if currentFindMatchIndex >= findMatches.count {
            currentFindMatchIndex = 0
        }
    }

    func findNext() {
        guard !findMatches.isEmpty else { return }
        currentFindMatchIndex = (currentFindMatchIndex + 1) % findMatches.count
        goToFindMatch(at: currentFindMatchIndex)
    }

    func findPrevious() {
        guard !findMatches.isEmpty else { return }
        currentFindMatchIndex = (currentFindMatchIndex - 1 + findMatches.count) % findMatches.count
        goToFindMatch(at: currentFindMatchIndex)
    }

    func replaceCurrentMatch() {
        guard var doc = document,
              findMatches.indices.contains(currentFindMatchIndex) else { return }
        let match = findMatches[currentFindMatchIndex]
        guard let pageIndex = doc.pages.firstIndex(where: { $0.pageNumber == match.pageNumber }) else { return }

        let text = doc.pages[pageIndex].displayText
        guard let updated = FindService.replace(
            in: text,
            query: findText,
            replacement: replaceText,
            at: match.range
        ) else { return }

        doc.pages[pageIndex].setDisplayText(updated)
        document = doc
        jobStore.scheduleSave(doc)
        refreshFindResults()
    }

    func replaceAllMatches() {
        guard var doc = document else { return }
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        for index in doc.pages.indices {
            let updated = FindService.replaceAll(
                in: doc.pages[index].displayText,
                query: query,
                replacement: replaceText
            )
            doc.pages[index].setDisplayText(updated)
        }
        document = doc
        jobStore.scheduleSave(doc)
        refreshFindResults()
    }

    private func goToFindMatch(at index: Int) {
        guard findMatches.indices.contains(index) else { return }
        let match = findMatches[index]
        goToPage(match.pageNumber - 1)
    }

    private func syncPageJumpText() {
        pageJumpText = "\(currentPageIndex + 1)"
    }
}
