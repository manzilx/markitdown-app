import AppKit
import UniformTypeIdentifiers

enum ExportOutcome: Equatable {
    case saved(URL)
    case cancelled
    case failed(AppError)
}

enum ExportService {
    static func markdown(for document: OCRDocument, totalPages: Int) -> String {
        var parts: [String] = ["# \(document.filename)", ""]
        for page in document.pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            if totalPages > 1 {
                parts.append("## Page \(page.pageNumber)")
                parts.append("")
            }
            parts.append(page.exportText)
            parts.append("")
        }
        if document.pages.count < totalPages {
            parts.append("<!-- Exported \(document.pages.count) of \(totalPages) pages (OCR not run on all pages) -->")
            parts.append("")
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    @MainActor
    static func exportMarkdown(document: OCRDocument, totalPages: Int, from window: NSWindow?) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.title = "Export Markdown"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = document.filename
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            + ".md"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }

        let text = markdown(for: document, totalPages: totalPages)
        return writeText(text, to: url, exportName: "Markdown")
    }

    @MainActor
    static func exportSearchablePDF(data: Data, suggestedFilename: String, from window: NSWindow?) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.title = "Export Searchable PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return writeData(data, to: url, exportName: "Searchable PDF")
    }

    @MainActor
    static func exportDOCX(data: Data, suggestedFilename: String, from window: NSWindow?) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.title = "Export Word Document"
        if let docxType = UTType(filenameExtension: "docx") {
            panel.allowedContentTypes = [docxType]
        }
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return writeData(data, to: url, exportName: "Word document")
    }

    // MARK: - Plain text

    static func plainText(for document: OCRDocument, totalPages: Int) -> String {
        var parts: [String] = []
        for page in document.pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            if totalPages > 1 {
                parts.append("Page \(page.pageNumber)")
                parts.append("")
            }
            parts.append(page.exportText)
            parts.append("")
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    @MainActor
    static func exportPlainText(document: OCRDocument, totalPages: Int, suggestedFilename: String, from window: NSWindow?) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.title = "Export Text"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return writeText(plainText(for: document, totalPages: totalPages), to: url, exportName: "Text")
    }

    // MARK: - Rich text (RTF)

    static func richText(for document: OCRDocument, totalPages: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: NSColor.textColor,
        ]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.textColor,
        ]

        output.append(NSAttributedString(string: document.filename + "\n\n", attributes: titleAttrs))
        for page in document.pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            if totalPages > 1 {
                output.append(NSAttributedString(string: "Page \(page.pageNumber)\n", attributes: headerAttrs))
            }
            output.append(NSAttributedString(string: page.exportText + "\n\n", attributes: bodyAttrs))
        }
        return output
    }

    @MainActor
    static func exportRTF(document: OCRDocument, totalPages: Int, suggestedFilename: String, from window: NSWindow?) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.title = "Export Rich Text"
        if let rtfType = UTType(filenameExtension: "rtf") {
            panel.allowedContentTypes = [rtfType]
        }
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        let attributed = richText(for: document, totalPages: totalPages)
        let range = NSRange(location: 0, length: attributed.length)
        guard let data = attributed.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
            return .failed(
                AppError(
                    kind: .export,
                    title: "Export failed",
                    userMessage: "OCR Review could not prepare the rich text export.",
                    recoveryAction: "Try exporting as plain text or Markdown."
                )
            )
        }
        return writeData(data, to: url, exportName: "Rich text")
    }

    private static func writeText(_ text: String, to url: URL, exportName: String) -> ExportOutcome {
        do {
            try validateWritableDestination(url)
            try text.write(to: url, atomically: true, encoding: .utf8)
            logSaved(exportName: exportName, url: url)
            return .saved(url)
        } catch {
            return exportFailure(exportName: exportName, url: url, error: error)
        }
    }

    static func writeData(_ data: Data, to url: URL, exportName: String) -> ExportOutcome {
        do {
            try validateWritableDestination(url)
            try data.write(to: url, options: .atomic)
            logSaved(exportName: exportName, url: url)
            return .saved(url)
        } catch {
            return exportFailure(exportName: exportName, url: url, error: error)
        }
    }

    private static func validateWritableDestination(_ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        if FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.isWritableFile(atPath: url.path)
        {
            throw CocoaError(.fileWriteNoPermission)
        }

        let probe = directory.appendingPathComponent(".ocrreview-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            throw error
        }
    }

    private static func logSaved(exportName: String, url: URL) {
        DiagnosticsLogger.shared.log(
            level: .info,
            event: "export.saved",
            context: ["type": exportName, "url": url.path]
        )
    }

    private static func exportFailure(exportName: String, url: URL, error: Error) -> ExportOutcome {
        DiagnosticsLogger.shared.log(
            level: .error,
            event: "export.failed",
            context: ["type": exportName, "url": url.path, "error": String(describing: error)]
        )
        return .failed(
            AppError(
                kind: .export,
                title: "Export failed",
                userMessage: "OCR Review could not save the \(exportName) file.",
                technicalMessage: String(describing: error),
                recoveryAction: "Choose a writable folder and try again."
            )
        )
    }
}
