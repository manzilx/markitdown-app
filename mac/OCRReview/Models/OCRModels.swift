import Foundation
import PDFKit

struct OCRBlock: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var confidence: Float
    /// Vision normalized bbox: [minX, minY, width, height], origin bottom-left.
    var bboxNormalized: [Double]?
    /// Original recognized text, preserved so edits can be reverted.
    var originalText: String?
    /// Blacked out — hidden on the page and removed from exports.
    var isRedacted: Bool

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        bboxNormalized: [Double]? = nil,
        originalText: String? = nil,
        isRedacted: Bool = false
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.bboxNormalized = bboxNormalized
        self.originalText = originalText ?? text
        self.isRedacted = isRedacted
    }

    enum CodingKeys: String, CodingKey {
        case id, text, confidence, bboxNormalized, originalText, isRedacted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        confidence = try c.decode(Float.self, forKey: .confidence)
        bboxNormalized = try c.decodeIfPresent([Double].self, forKey: .bboxNormalized)
        originalText = try c.decodeIfPresent(String.self, forKey: .originalText)
        isRedacted = try c.decodeIfPresent(Bool.self, forKey: .isRedacted) ?? false
    }

    var isLowConfidence: Bool {
        confidence < VisionOCRService.lowConfidenceThreshold
    }

    /// Bottom-left Y for reading-order sorts. Guards malformed persisted bboxes —
    /// `bboxNormalized?[1]` would crash on a short array from a hand-edited or
    /// foreign-port job file.
    var sortY: Double {
        guard let box = bboxNormalized, box.count >= 4 else { return 0 }
        return box[1]
    }

    var pristineText: String {
        originalText ?? text
    }

    var hasEdits: Bool {
        text != pristineText
    }

    mutating func revertToOriginal() {
        text = pristineText
    }
}

struct OCRPage: Identifiable, Codable, Equatable {
    let id: UUID
    var pageNumber: Int
    var ocrText: String
    var editedText: String?
    var blocks: [OCRBlock]

    init(
        id: UUID = UUID(),
        pageNumber: Int,
        ocrText: String,
        editedText: String? = nil,
        blocks: [OCRBlock] = []
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.ocrText = ocrText
        self.editedText = editedText
        self.blocks = blocks
    }

    var displayText: String {
        if let editedText, !editedText.isEmpty {
            return editedText
        }
        return ocrText
    }

    /// Text used for exports. Excludes redacted regions; falls back to `displayText`
    /// when nothing is redacted (or the page has no block geometry).
    var exportText: String {
        let redacted = blocks.filter(\.isRedacted)
        guard !redacted.isEmpty else { return displayText }
        let kept = ReadingOrder.sorted(blocks: blocks.filter { !$0.isRedacted })
            .map(\.text)
            .filter { !$0.isEmpty }
        return kept.joined(separator: "\n")
    }

    var hasRedactions: Bool {
        blocks.contains(where: \.isRedacted)
    }

    mutating func setDisplayText(_ text: String) {
        editedText = text
    }

    mutating func syncEditedTextFromBlocks() {
        editedText = ReadingOrder.sorted(blocks: blocks).map(\.text).joined(separator: "\n")
    }

    var lowConfidenceBlocks: [OCRBlock] {
        blocks.filter(\.isLowConfidence)
    }

    /// Low-confidence blocks ordered top-to-bottom for review navigation.
    var issuesInReadingOrder: [OCRBlock] {
        ReadingOrder.sorted(blocks: lowConfidenceBlocks)
    }

    var hasEdits: Bool {
        (editedText != nil && editedText != ocrText) || blocks.contains(where: \.hasEdits)
    }

    mutating func revertToOriginal() {
        editedText = nil
        for index in blocks.indices {
            blocks[index].revertToOriginal()
        }
    }
}

struct OCRDocument: Identifiable, Codable, Equatable {
    let id: UUID
    var filename: String
    var sourcePath: String
    var createdAt: Date
    var pages: [OCRPage]
    var engine: String
    /// Total pages in the source PDF/image (may exceed OCR'd pages).
    var totalPageCount: Int

    init(
        id: UUID = UUID(),
        filename: String,
        sourcePath: String,
        createdAt: Date = .now,
        pages: [OCRPage] = [],
        engine: String = "vision",
        totalPageCount: Int? = nil
    ) {
        self.id = id
        self.filename = filename
        self.sourcePath = sourcePath
        self.createdAt = createdAt
        self.pages = pages
        self.engine = engine
        self.totalPageCount = totalPageCount ?? max(pages.map(\.pageNumber).max() ?? 0, pages.count)
    }

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    func page(number: Int) -> OCRPage? {
        pages.first { $0.pageNumber == number }
    }

    var ocrPageCount: Int {
        pages.count
    }

    /// Total low-confidence regions across all recognized pages.
    var issueCount: Int {
        pages.reduce(0) { $0 + $1.lowConfidenceBlocks.count }
    }

    /// Mean recognition confidence (0–1) across all blocks with geometry.
    var averageConfidence: Double {
        let blocks = pages.flatMap(\.blocks).filter { $0.bboxNormalized != nil }
        guard !blocks.isEmpty else { return 1 }
        let sum = blocks.reduce(0.0) { $0 + Double($1.confidence) }
        return sum / Double(blocks.count)
    }
}

struct PDFDocumentReference: Codable, Equatable {
    let urlPath: String
    let pageCount: Int

    var url: URL { URL(fileURLWithPath: urlPath) }
}

enum LoadedDocument {
    case pdf(PDFDocumentReference)
    case image(URL)

    var pageCount: Int {
        switch self {
        case .pdf(let ref): ref.pageCount
        case .image: 1
        }
    }
}

enum OCRError: LocalizedError {
    case openFailed
    case renderFailed
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .openFailed: "Could not open the file."
        case .renderFailed: "Could not render the page for OCR."
        case .emptyDocument: "The document has no pages."
        }
    }
}
