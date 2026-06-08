import AppKit
import PDFKit
import Vision

enum VisionOCRService {
    static let lowConfidenceThreshold: Float = 0.85

    /// Concurrency for whole-document recognition. Vision leans on the Neural Engine/GPU,
    /// so we cap workers to avoid thrashing while still using multiple cores.
    static var maxConcurrentOCR: Int {
        min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    // MARK: - Single page (reuses the in-memory document — no disk re-parse)

    /// Render + recognize a page. Only safe for a PDFPage from a document NOT shared with
    /// the main thread (e.g. the per-worker documents in `recognizeAllPages`). For the
    /// shared on-screen document, render on the main actor and call `recognize(cgImage:)`.
    static func recognize(pdfPage: PDFPage, pageNumber: Int) async throws -> OCRPage {
        let cgImage = try autoreleasepool { () throws -> CGImage in
            guard let image = renderPage(pdfPage, scale: 2.0) else { throw OCRError.renderFailed }
            return image
        }
        return try await recognize(cgImage: cgImage, pageNumber: pageNumber)
    }

    static func recognize(imageURL url: URL, pageNumber: Int = 1) async throws -> OCRPage {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw OCRError.openFailed
        }
        return try await recognize(cgImage: cgImage, pageNumber: pageNumber)
    }

    // MARK: - Whole document (parallel)

    /// Recognize every page of a PDF concurrently. Each worker opens its own PDFDocument
    /// from the file URL so PDFKit state is never shared across threads.
    static func recognizeAllPages(
        pdfURL: URL,
        pageCount: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [OCRPage] {
        guard pageCount > 0 else { throw OCRError.emptyDocument }

        let workerCount = min(maxConcurrentOCR, pageCount)
        let counter = ProgressCounter(total: pageCount, onProgress: onProgress)
        var results = [OCRPage?](repeating: nil, count: pageCount)

        try await withThrowingTaskGroup(of: [(Int, OCRPage)].self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    guard let doc = PDFDocument(url: pdfURL) else { throw OCRError.openFailed }
                    var produced: [(Int, OCRPage)] = []
                    var index = worker
                    while index < pageCount {
                        // Tolerate a single bad page instead of failing the whole batch.
                        if let page = doc.page(at: index),
                           let ocr = try? await recognize(pdfPage: page, pageNumber: index + 1) {
                            produced.append((index, ocr))
                        }
                        await counter.tick()
                        index += workerCount
                    }
                    return produced
                }
            }
            for try await batch in group {
                for (index, page) in batch where index >= 0 && index < results.count {
                    results[index] = page
                }
            }
        }

        let pages = results.compactMap { $0 }
        if pages.isEmpty { throw OCRError.emptyDocument }
        return pages
    }

    // MARK: - Core recognition

    /// Recognize a pre-rendered image off the main thread. Render the shared on-screen
    /// document on the main actor, then hand the CGImage here.
    static func recognize(cgImage: CGImage, pageNumber: Int) async throws -> OCRPage {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var blocks: [OCRBlock] = []
                var lines: [String] = []

                for observation in observations.sorted(by: { a, b in
                    a.boundingBox.minY > b.boundingBox.minY
                }) {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let box = observation.boundingBox
                    blocks.append(
                        OCRBlock(
                            text: candidate.string,
                            confidence: candidate.confidence,
                            bboxNormalized: [
                                Double(box.origin.x),
                                Double(box.origin.y),
                                Double(box.width),
                                Double(box.height),
                            ]
                        )
                    )
                    lines.append(candidate.string)
                }

                let text = lines.joined(separator: "\n")
                continuation.resume(
                    returning: OCRPage(
                        pageNumber: pageNumber,
                        ocrText: text,
                        blocks: blocks
                    )
                )
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

/// Thread-safe progress counter that forwards normalized progress to the main thread.
private actor ProgressCounter {
    private var done = 0
    private let total: Int
    private let onProgress: @Sendable (Double) -> Void

    init(total: Int, onProgress: @escaping @Sendable (Double) -> Void) {
        self.total = max(total, 1)
        self.onProgress = onProgress
    }

    func tick() {
        done += 1
        onProgress(Double(done) / Double(total))
    }
}
