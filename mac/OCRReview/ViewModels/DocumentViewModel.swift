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
    @Published var errorMessage: String?
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

    let pdfController = PDFViewController()

    private let jobStore = JobStore.shared

    var totalPages: Int {
        if let pdfDocument { return pdfDocument.pageCount }
        return document?.totalPageCount ?? 1
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
        return "No OCR for this page yet. Click Recognize Text or it will run when you open the page."
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

    func open(url: URL) async {
        errorMessage = nil
        isProcessing = true
        progress = 0
        defer { isProcessing = false }

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
            errorMessage = error.localizedDescription
            document = nil
            loadedSource = nil
            pdfDocument = nil
        }
    }

    func openRecent(_ recent: OCRDocument) {
        errorMessage = nil
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
        } catch {
            errorMessage = error.localizedDescription
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
        Task { [weak self] in
            guard let self else { return }
            if let page = await self.visionPrefetch(index: next) {
                self.mergePrefetchedPage(page)
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

    private func mergePrefetchedPage(_ page: OCRPage) {
        guard var doc = document else { return }
        guard doc.page(number: page.pageNumber) == nil else { return }
        doc.pages.append(page)
        doc.pages.sort { $0.pageNumber < $1.pageNumber }
        document = doc
        jobStore.scheduleSave(doc)
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
        Task { await recognizePage(at: currentPageIndex) }
    }

    func recognizeAllPages() {
        Task {
            let total = totalPages
            if total > 50 {
                let alert = NSAlert()
                alert.messageText = "Recognize all \(total) pages?"
                alert.informativeText = "This may take a long time with Apple Vision. Prefer recognizing one page at a time for large documents."
                alert.addButton(withTitle: "Recognize All")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            await recognizeAllPagesAsync()
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

    private func recognizePage(at index: Int) async {
        guard var doc = document, loadedSource != nil else { return }
        if doc.page(number: index + 1) != nil { return }

        isProcessing = true
        defer { isProcessing = false }

        do {
            let engine = OCRSettings.selectedEngine
            let page = try await recognizeSinglePage(at: index, engine: engine)
            if let existing = doc.pages.firstIndex(where: { $0.pageNumber == page.pageNumber }) {
                doc.pages[existing] = page
            } else {
                doc.pages.append(page)
            }
            doc.pages.sort { $0.pageNumber < $1.pageNumber }
            doc.engine = engine
            document = doc
            jobStore.save(doc)
            if page.pageNumber == currentPageIndex + 1 {
                selectedBlockID = nil
            }
            refreshFindResults()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recognizeAllPagesAsync() async {
        guard let source = loadedSource else { return }
        isProcessing = true
        progress = 0
        defer {
            isProcessing = false
            progress = 1
        }

        do {
            let engine = OCRSettings.selectedEngine
            let pages: [OCRPage]

            switch source {
            case .pdf:
                if engine == "vision" {
                    let url = try resolvedSourceURL()
                    let pageCount = totalPages
                    pages = try await VisionOCRService.recognizeAllPages(
                        pdfURL: url,
                        pageCount: pageCount
                    ) { [weak self] value in
                        Task { @MainActor in self?.progress = value }
                    }
                } else {
                    try await EngineSidecarClient.ensureAvailable()
                    var collected: [OCRPage] = []
                    for index in 0..<totalPages {
                        let page = try await recognizeSinglePage(at: index, engine: engine)
                        collected.append(page)
                        progress = Double(index + 1) / Double(totalPages)
                    }
                    pages = collected
                }
            case .image(let url):
                if engine == "vision" {
                    pages = [try await VisionOCRService.recognize(imageURL: url, pageNumber: 1)]
                } else {
                    try await EngineSidecarClient.ensureAvailable()
                    pages = [try await SidecarOCRService.recognize(imageURL: url, pageNumber: 1, engine: engine)]
                }
            }

            if var doc = document {
                doc.pages = pages
                doc.engine = engine
                document = doc
                jobStore.save(doc)
                refreshFindResults()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func appendPDFs() {
        guard let pdf = pdfDocument else {
            errorMessage = "Open a PDF before appending other files."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Append PDFs"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let added = PDFToolsService.appendPDFs(from: panel.urls, to: pdf)
        guard added > 0 else {
            errorMessage = "Could not append any pages from the selected PDFs."
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
            errorMessage = "Could not combine the selected PDFs."
            return
        }

        guard let savedURL = PDFToolsService.savePDF(
            combined,
            suggestedFilename: "combined.pdf",
            from: NSApp.keyWindow
        ) else { return }

        Task { await open(url: savedURL) }
    }

    func splitPDFPrompt() {
        guard pdfDocument != nil else {
            errorMessage = "Open a PDF before splitting."
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
            errorMessage = "Invalid page range. Use e.g. 3-10 or 5."
            return
        }
        guard let extracted = PDFToolsService.extractPages(from: pdf, range: range) else {
            errorMessage = "Could not extract pages."
            return
        }

        let filename = "pages_\(range.lowerBound)-\(range.upperBound).pdf"
        if PDFToolsService.savePDF(extracted, suggestedFilename: filename, from: NSApp.keyWindow) == nil {
            errorMessage = "Could not save extracted PDF."
        }
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

    func deletePage(at index: Int) {
        guard let pdf = pdfDocument, pdf.pageCount > 1 else {
            errorMessage = "Cannot delete the only page in the document."
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

        if var doc = document {
            doc.pages = PageStructureService.remapAfterDelete(
                pages: doc.pages,
                deletedPageNumber: index + 1
            )
            doc.totalPageCount = pdf.pageCount
            document = doc
            jobStore.save(doc)
        }

        if currentPageIndex >= pdf.pageCount {
            currentPageIndex = max(0, pdf.pageCount - 1)
        } else if index < currentPageIndex {
            currentPageIndex -= 1
        }
        selectedBlockID = nil
        syncPageJumpText()
    }

    func movePage(from sourceIndex: Int, to destIndex: Int) {
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
        ExportService.exportMarkdown(document: document, totalPages: totalPages, from: NSApp.keyWindow)
    }

    func exportDOCX() {
        guard let document else { return }
        Task {
            isProcessing = true
            errorMessage = nil
            defer { isProcessing = false }

            do {
                try await EngineSidecarClient.ensureAvailable()
                let docxData = try await EngineSidecarClient.exportDOCX(document: document)
                let stem = document.filename
                    .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".jpg", with: "", options: .caseInsensitive)
                ExportService.exportDOCX(
                    data: docxData,
                    suggestedFilename: "\(stem).docx",
                    from: NSApp.keyWindow
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportSearchablePDF() {
        guard let document else { return }

        Task {
            isProcessing = true
            errorMessage = nil
            defer { isProcessing = false }

            do {
                try await EngineSidecarClient.ensureAvailable()
                let sourceURL = try resolvedSourceURL()
                let pdfData = try await EngineSidecarClient.exportSearchablePDF(
                    sourceURL: sourceURL,
                    document: document
                )
                let stem = document.filename
                    .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".jpg", with: "", options: .caseInsensitive)
                ExportService.exportSearchablePDF(
                    data: pdfData,
                    suggestedFilename: "\(stem)_searchable.pdf",
                    from: NSApp.keyWindow
                )
            } catch {
                errorMessage = error.localizedDescription
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
        ExportService.exportPlainText(
            document: document,
            totalPages: totalPages,
            suggestedFilename: "\(filenameStem()).txt",
            from: NSApp.keyWindow
        )
    }

    func exportRTF() {
        guard let document else { return }
        ExportService.exportRTF(
            document: document,
            totalPages: totalPages,
            suggestedFilename: "\(filenameStem()).rtf",
            from: NSApp.keyWindow
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
