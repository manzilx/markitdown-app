import PDFKit
import UniformTypeIdentifiers

enum PDFToolsService {
    /// Parse a 1-based page range like `3-10` or `5`.
    static func parsePageRange(_ input: String, totalPages: Int) -> ClosedRange<Int>? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-", maxSplits: 1).compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            guard parts.count == 2, parts[0] >= 1, parts[1] >= parts[0], parts[1] <= totalPages else {
                return nil
            }
            return parts[0]...parts[1]
        }
        if let single = Int(trimmed), single >= 1, single <= totalPages {
            return single...single
        }
        return nil
    }

    static func extractPages(from pdf: PDFDocument, range: ClosedRange<Int>) -> PDFDocument? {
        let output = PDFDocument()
        for pageNumber in range {
            let index = pageNumber - 1
            guard index >= 0, index < pdf.pageCount, let page = pdf.page(at: index) else { continue }
            output.insert(page, at: output.pageCount)
        }
        return output.pageCount > 0 ? output : nil
    }

    static func appendPDFs(from urls: [URL], to pdf: PDFDocument) -> Int {
        var added = 0
        for url in urls {
            guard let other = PDFDocument(url: url) else { continue }
            for index in 0..<other.pageCount {
                guard let page = other.page(at: index) else { continue }
                pdf.insert(page, at: pdf.pageCount)
                added += 1
            }
        }
        return added
    }

    static func combine(urls: [URL]) -> PDFDocument? {
        guard !urls.isEmpty else { return nil }
        let output = PDFDocument()
        for url in urls {
            guard let pdf = PDFDocument(url: url) else { continue }
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { continue }
                output.insert(page, at: output.pageCount)
            }
        }
        return output.pageCount > 0 ? output : nil
    }

    @MainActor
    static func savePDFOutcome(_ pdf: PDFDocument, suggestedFilename: String, from window: NSWindow?) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.title = "Save PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRReview-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard pdf.write(to: tempURL) else {
            let error = AppError(
                kind: .export,
                title: "Save failed",
                userMessage: "OCR Review could not prepare the PDF for saving.",
                recoveryAction: "Try again or save to another location."
            )
            DiagnosticsLogger.shared.log(level: .error, event: "pdf.save_prepare_failed", context: ["url": url.path])
            return .failed(error)
        }

        do {
            let data = try Data(contentsOf: tempURL)
            return ExportService.writeData(data, to: url, exportName: "PDF")
        } catch {
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "pdf.save_failed",
                context: ["url": url.path, "error": String(describing: error)]
            )
            return .failed(
                AppError(
                    kind: .export,
                    title: "Save failed",
                    userMessage: "OCR Review could not save the PDF.",
                    technicalMessage: String(describing: error),
                    recoveryAction: "Choose a writable folder and try again."
                )
            )
        }
    }

    @MainActor
    static func savePDF(_ pdf: PDFDocument, suggestedFilename: String, from window: NSWindow?) -> URL? {
        if case .saved(let url) = savePDFOutcome(pdf, suggestedFilename: suggestedFilename, from: window) {
            return url
        }
        return nil
    }
}
