import AppKit
import UniformTypeIdentifiers

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
    static func exportMarkdown(document: OCRDocument, totalPages: Int, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "Export Markdown"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = document.filename
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            + ".md"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = markdown(for: document, totalPages: totalPages)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    static func exportSearchablePDF(data: Data, suggestedFilename: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "Export Searchable PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    @MainActor
    static func exportDOCX(data: Data, suggestedFilename: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "Export Word Document"
        if let docxType = UTType(filenameExtension: "docx") {
            panel.allowedContentTypes = [docxType]
        }
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
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
    static func exportPlainText(document: OCRDocument, totalPages: Int, suggestedFilename: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "Export Text"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? plainText(for: document, totalPages: totalPages).write(to: url, atomically: true, encoding: .utf8)
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
    static func exportRTF(document: OCRDocument, totalPages: Int, suggestedFilename: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "Export Rich Text"
        if let rtfType = UTType(filenameExtension: "rtf") {
            panel.allowedContentTypes = [rtfType]
        }
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let attributed = richText(for: document, totalPages: totalPages)
        let range = NSRange(location: 0, length: attributed.length)
        guard let data = attributed.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
