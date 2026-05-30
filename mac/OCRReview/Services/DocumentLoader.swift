import AppKit
import PDFKit
import UniformTypeIdentifiers

enum DocumentLoader {
    static let supportedTypes: [UTType] = [.pdf, .png, .jpeg, .tiff]
    static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "tif", "tiff", "heic"]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(from url: URL) throws -> LoadedDocument {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
                throw OCRError.openFailed
            }
            return .pdf(PDFDocumentReference(urlPath: url.path, pageCount: doc.pageCount))
        }

        if ["png", "jpg", "jpeg", "tif", "tiff", "heic"].contains(ext) {
            return .image(url)
        }

        throw OCRError.openFailed
    }

    static func pdfDocument(for ref: PDFDocumentReference) -> PDFDocument? {
        PDFDocument(url: ref.url)
    }

    static func page(_ index: Int, in ref: PDFDocumentReference) -> PDFPage? {
        pdfDocument(for: ref)?.page(at: index)
    }

    static func writeTempPDF(_ document: PDFDocument, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OCRReview", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        guard document.write(to: url) else {
            throw OCRError.openFailed
        }
        return url
    }
}
